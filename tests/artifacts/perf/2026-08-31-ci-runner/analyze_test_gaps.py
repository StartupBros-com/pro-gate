#!/usr/bin/env python3
"""Rank output-silence intervals in a timestamped GitHub Actions test log.

A silent interval is an off-CPU/wait candidate, not proof by itself. The report
is intended to be triangulated with explicit waits in the test sources.
"""

from __future__ import annotations

import json
import math
import re
from datetime import datetime
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
INPUT = OUT_DIR / "representative-run-33443036305-test.log"
OUTPUT = OUT_DIR / "hosted-log-gap-analysis.json"
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


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def nearest_rank(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(quantile * len(ordered)) - 1)]


def clean_message(message: str) -> str:
    message = ANSI_RE.sub("", message)
    return message[:240]


def parse_lines() -> list[tuple[datetime, str]]:
    lines = []
    for raw_line in INPUT.read_text(errors="replace").replace("﻿", "").splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = TIMESTAMP_RE.match(line)
        if match:
            lines.append((parse_time(match.group(1)), clean_message(match.group(2))))
    return lines


def boundaries(lines: list[tuple[datetime, str]]) -> list[tuple[str, datetime, datetime]]:
    starts = [stamp for stamp, line in lines if line == "##[group]Run bash tests/engine.test.sh"]
    all_pass = [stamp for stamp, line in lines if "ALL PASS" in line]
    node_done = next(stamp for stamp, line in lines if "# duration_ms " in line)
    if len(starts) != 1 or len(all_pass) < 7:
        raise RuntimeError("representative log does not contain the expected CI test boundaries")
    completion_points = all_pass[:4] + [node_done] + all_pass[4:7]
    result = []
    previous = starts[0]
    for name, completion in zip(TEST_NAMES, completion_points, strict=True):
        result.append((name, previous, completion))
        previous = completion
    return result


def summarize(lines: list[tuple[datetime, str]]) -> dict[str, object]:
    script_bounds = boundaries(lines)
    intervals = []
    for (before_at, before), (after_at, after) in zip(lines, lines[1:]):
        elapsed = (after_at - before_at).total_seconds()
        if elapsed < 1.0:
            continue
        script = next(
            (
                name
                for name, started, completed in script_bounds
                if started <= before_at < completed
            ),
            "outside-test-boundary",
        )
        intervals.append(
            {
                "script": script,
                "started_at": before_at.isoformat(),
                "ended_at": after_at.isoformat(),
                "elapsed_s": round(elapsed, 6),
                "before": before,
                "after": after,
            }
        )

    scripts = {}
    for name, started, completed in script_bounds:
        wall_s = (completed - started).total_seconds()
        gaps = [item["elapsed_s"] for item in intervals if item["script"] == name]
        scripts[name] = {
            "wall_s": round(wall_s, 6),
            "silent_intervals_ge_1s": len(gaps),
            "silent_cumulative_s": round(sum(gaps), 6),
            "silent_share_of_wall_pct": round(100 * sum(gaps) / wall_s, 2),
            "silent_p50_s": round(nearest_rank(gaps, 0.50), 6) if gaps else 0,
            "silent_p95_s": round(nearest_rank(gaps, 0.95), 6) if gaps else 0,
            "silent_max_s": round(max(gaps), 6) if gaps else 0,
        }

    return {
        "schema_version": 1,
        "source": INPUT.name,
        "run_id": 33443036305,
        "method": (
            "Difference consecutive GitHub log timestamps; retain intervals >=1s and assign each "
            "to the active test script. Silence is a wait candidate, not standalone proof."
        ),
        "scripts": scripts,
        "top_intervals": sorted(intervals, key=lambda item: item["elapsed_s"], reverse=True)[:30],
        "intervals": intervals,
    }


def main() -> None:
    report = summarize(parse_lines())
    OUTPUT.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"scripts": report["scripts"], "top_intervals": report["top_intervals"][:12]}, indent=2))


if __name__ == "__main__":
    main()
