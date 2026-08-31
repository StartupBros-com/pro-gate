#!/usr/bin/env python3
"""Collect a service-level baseline from successful GitHub Actions CI runs.

GitHub-hosted runners are ephemeral, so this captures runner image identity and
region per sample rather than pretending the observations came from one host.
"""

from __future__ import annotations

import csv
import io
import json
import math
import re
import subprocess
import sys
from collections import Counter
from statistics import median, pstdev
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from zipfile import ZipFile

REPO = "StartupBros-com/pro-gate"
WORKFLOW = "CI"
JOB_NAME = "trusted check"
SAMPLE_COUNT = 20
OUT_DIR = Path(__file__).resolve().parent
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T[^ ]+Z) (.*)$")
TEST_NAMES = (
    "engine.test.sh",
    "daemon-reload.test.sh",
    "autoupdate.test.sh",
    "browser-launch.test.sh",
    "cdp-salvage.test.mjs",
    "distribution.test.sh",
    "release-train.test.sh",
    "release-assets.test.sh",
)


def run(command: list[str], *, binary: bool = False) -> str | bytes:
    completed = subprocess.run(command, check=True, capture_output=True)
    if binary:
        return completed.stdout
    return completed.stdout.decode("utf-8")


def gh_json(*args: str) -> Any:
    return json.loads(run(["gh", *args]))


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def seconds_between(start: str, end: str) -> float:
    return (parse_time(end) - parse_time(start)).total_seconds()


def nearest_rank(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(quantile * len(ordered)) - 1)
    return ordered[index]


def summarize(values: list[float]) -> dict[str, float | int | bool]:
    mean = sum(values) / len(values)
    center = median(values)
    max_drift = max(abs(value - center) / center for value in values) if center else 0
    return {
        "samples": len(values),
        "min_s": round(min(values), 3),
        "mean_s": round(mean, 3),
        "population_stdev_s": round(pstdev(values), 3),
        "cv_pct": round(100 * pstdev(values) / mean, 3) if mean else 0,
        "max_drift_from_median_pct": round(100 * max_drift, 3),
        "p50_s": round(nearest_rank(values, 0.50), 3),
        "p95_s": round(nearest_rank(values, 0.95), 3),
        "p99_s": round(nearest_rank(values, 0.99), 3),
        "p99_9_s": round(nearest_rank(values, 0.999), 3),
        "p99_99_s": round(nearest_rank(values, 0.9999), 3),
        "max_s": round(max(values), 3),
        "upper_tails_conservative": len(values) < 1000,
    }


def strip_log_prefix(text: str) -> list[str]:
    lines = []
    for raw_line in text.replace("﻿", "").splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = TIMESTAMP_RE.match(line)
        lines.append(match.group(2) if match else line)
    return lines


def extract_fingerprint(setup_log: str) -> dict[str, Any]:
    lines = strip_log_prefix(setup_log)
    excerpt = [
        line
        for line in lines
        if line.startswith(
            (
                "Current runner version:",
                "Hosted Compute Agent",
                "Azure Region:",
                "Image:",
                "Included Software:",
                "Image Release:",
            )
        )
        or re.fullmatch(r"(Ubuntu|[0-9]{4,8}(?:\.[0-9]+){1,3}|LTS)", line)
    ]

    def first(pattern: str) -> str | None:
        regex = re.compile(pattern)
        for line in lines:
            match = regex.search(line)
            if match:
                return match.group(1)
        return None

    image_index = next((i for i, line in enumerate(lines) if line == "Image: ubuntu-24.04"), None)
    image_version = None
    if image_index is not None:
        for line in lines[image_index + 1 : image_index + 4]:
            match = re.fullmatch(r"Version: (.+)", line)
            if match:
                image_version = match.group(1)
                break

    return {
        "runner_version": first(r"Current runner version: '([^']+)'"),
        "azure_region": first(r"Azure Region: (.+)"),
        "image": first(r"Image: (ubuntu-24\.04)"),
        "image_version": image_version,
        "excerpt": excerpt,
    }


def timestamped_lines(test_log: str) -> list[tuple[datetime, str]]:
    parsed = []
    for raw_line in test_log.replace("﻿", "").splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = TIMESTAMP_RE.match(line)
        if match:
            parsed.append((parse_time(match.group(1)), match.group(2)))
    return parsed


def extract_test_durations(test_log: str, step_started_at: str) -> dict[str, float]:
    lines = timestamped_lines(test_log)
    all_pass = [stamp for stamp, line in lines if "ALL PASS" in line]
    node_done = next((stamp for stamp, line in lines if "# duration_ms " in line), None)
    if len(all_pass) < 7 or node_done is None:
        return {}
    completion_points = all_pass[:4] + [node_done] + all_pass[4:7]
    previous = parse_time(step_started_at)
    durations: dict[str, float] = {}
    for name, completion in zip(TEST_NAMES, completion_points, strict=True):
        durations[name] = round((completion - previous).total_seconds(), 3)
        previous = completion
    return durations


def archive_member(archive: ZipFile, suffix: str) -> str | None:
    names = archive.namelist()
    name = next((candidate for candidate in names if candidate.endswith(suffix)), None)
    if name is None:
        # GitHub compacts older run logs into one aggregate job file after the
        # step-scoped members expire. It retains the same timestamped content.
        name = next(
            (
                candidate
                for candidate in names
                if candidate.startswith("0_") and candidate.endswith(".txt")
            ),
            None,
        )
    if name is None:
        # API job/step timestamps outlive detailed log retention. Keep those
        # service-level samples and make the missing attribution explicit.
        return None
    return archive.read(name).decode("utf-8", errors="replace")


def collect() -> list[dict[str, Any]]:
    runs = gh_json(
        "run",
        "list",
        "--repo",
        REPO,
        "--workflow",
        WORKFLOW,
        "--status",
        "success",
        "--limit",
        "60",
        "--json",
        "databaseId,workflowName,displayTitle,event,conclusion,createdAt,startedAt,updatedAt,headSha,url",
    )
    samples = []
    for workflow_run in runs:
        jobs_response = gh_json(
            "api", f"repos/{REPO}/actions/runs/{workflow_run['databaseId']}/jobs?per_page=100"
        )
        job = next(
            (
                candidate
                for candidate in jobs_response["jobs"]
                if candidate["name"] == JOB_NAME and candidate["conclusion"] == "success"
            ),
            None,
        )
        if job is None:
            continue

        steps = {
            step["name"]: round(seconds_between(step["started_at"], step["completed_at"]), 3)
            for step in job["steps"]
            if step["started_at"] and step["completed_at"]
        }
        logs = run(
            ["gh", "api", f"repos/{REPO}/actions/runs/{workflow_run['databaseId']}/logs"],
            binary=True,
        )
        with ZipFile(io.BytesIO(logs)) as archive:
            setup_log = archive_member(archive, "1_Set up job.txt")
            test_log = archive_member(archive, "6_Run tests.txt")
        test_step = next(step for step in job["steps"] if step["name"] == "Run tests")
        logs_available = setup_log is not None and test_log is not None

        samples.append(
            {
                "run_id": workflow_run["databaseId"],
                "url": workflow_run["url"],
                "event": workflow_run["event"],
                "title": workflow_run["displayTitle"],
                "head_sha": workflow_run["headSha"],
                "created_at": workflow_run["createdAt"],
                "updated_at": workflow_run["updatedAt"],
                "workflow_elapsed_s": round(
                    seconds_between(workflow_run["createdAt"], workflow_run["updatedAt"]), 3
                ),
                "job_elapsed_s": round(seconds_between(job["started_at"], job["completed_at"]), 3),
                "queue_s": round(seconds_between(workflow_run["createdAt"], job["started_at"]), 3),
                "runner_name": job["runner_name"],
                "runner_group_name": job["runner_group_name"],
                "labels": job["labels"],
                "logs_available": logs_available,
                "steps_s": steps,
                "test_scripts_s": (
                    extract_test_durations(test_log, test_step["started_at"])
                    if test_log is not None
                    else {}
                ),
                "runner_fingerprint": (
                    extract_fingerprint(setup_log)
                    if setup_log is not None
                    else {
                        "runner_version": None,
                        "azure_region": None,
                        "image": "ubuntu-24.04",
                        "image_version": None,
                        "excerpt": [],
                    }
                ),
            }
        )
        print(f"collected {len(samples):02d}/{SAMPLE_COUNT}: {workflow_run['databaseId']}", file=sys.stderr)
        if len(samples) == SAMPLE_COUNT:
            break

    if len(samples) != SAMPLE_COUNT:
        raise RuntimeError(f"needed {SAMPLE_COUNT} successful runs, found {len(samples)}")
    return samples


def write_outputs(samples: list[dict[str, Any]]) -> None:
    workflow_values = [sample["workflow_elapsed_s"] for sample in samples]
    metrics = {
        "workflow_elapsed": summarize(workflow_values),
        "job_elapsed": summarize([sample["job_elapsed_s"] for sample in samples]),
        "queue": summarize([sample["queue_s"] for sample in samples]),
        "throughput": {
            "successful_jobs_per_hour_from_mean_workflow": round(
                3600 / (sum(workflow_values) / len(workflow_values)), 6
            ),
            "bytes_per_second": None,
            "note": "Byte throughput is not meaningful for this correctness-oriented CI workload.",
        },
    }
    step_names = sorted({name for sample in samples for name in sample["steps_s"]})
    step_metrics = {
        name: summarize([sample["steps_s"][name] for sample in samples if name in sample["steps_s"]])
        for name in step_names
    }
    script_metrics = {
        name: summarize(
            [sample["test_scripts_s"][name] for sample in samples if name in sample["test_scripts_s"]]
        )
        for name in TEST_NAMES
    }
    fingerprints = Counter(
        (
            sample["runner_fingerprint"]["image_version"],
            sample["runner_fingerprint"]["azure_region"],
            sample["runner_fingerprint"]["runner_version"],
        )
        for sample in samples
    )
    summary = {
        "schema_version": 1,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "scenario": {
            "repository": REPO,
            "workflow": WORKFLOW,
            "job": JOB_NAME,
            "runner_label": "ubuntu-24.04",
            "golden_output": "trusted check concludes success after all validation and test commands",
            "primary_metric": "workflow and Run tests wall-clock p95",
            "profiled_content_revision": run(
                ["git", "rev-parse", "origin/main"]
            ).strip(),
            "sample_window": {
                "oldest_created_at": min(sample["created_at"] for sample in samples),
                "newest_created_at": max(sample["created_at"] for sample in samples),
                "distinct_head_shas": len({sample["head_sha"] for sample in samples}),
            },
        },
        "sample_count": len(samples),
        "samples_with_detailed_logs": sum(sample["logs_available"] for sample in samples),
        "quantile_method": "nearest-rank",
        "comparability_limit": (
            "GitHub-hosted runners are ephemeral. Samples share the ubuntu-24.04 label but not a "
            "physical host; use this as a service-level baseline, not a microbenchmark A/B baseline."
        ),
        "fingerprint_counts": [
            {
                "image_version": key[0],
                "azure_region": key[1],
                "runner_version": key[2],
                "samples": count,
            }
            for key, count in sorted(
                fingerprints.items(), key=lambda item: (-item[1], repr(item[0]))
            )
        ],
        "metrics": metrics,
        "steps": step_metrics,
        "test_scripts": script_metrics,
    }

    (OUT_DIR / "ci-baseline-samples.json").write_text(json.dumps(samples, indent=2) + "\n")
    (OUT_DIR / "ci-baseline-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    with (OUT_DIR / "ci-baseline-samples.csv").open("w", newline="") as csv_file:
        writer = csv.writer(csv_file, lineterminator="\n")
        writer.writerow(
            [
                "run_id",
                "created_at",
                "head_sha",
                "image_version",
                "azure_region",
                "workflow_elapsed_s",
                "job_elapsed_s",
                "queue_s",
                "run_tests_s",
                *TEST_NAMES,
                "url",
            ]
        )
        for sample in samples:
            writer.writerow(
                [
                    sample["run_id"],
                    sample["created_at"],
                    sample["head_sha"],
                    sample["runner_fingerprint"]["image_version"],
                    sample["runner_fingerprint"]["azure_region"],
                    sample["workflow_elapsed_s"],
                    sample["job_elapsed_s"],
                    sample["queue_s"],
                    sample["steps_s"].get("Run tests"),
                    *(sample["test_scripts_s"].get(name) for name in TEST_NAMES),
                    sample["url"],
                ]
            )

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    write_outputs(collect())
