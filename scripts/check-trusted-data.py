#!/usr/bin/env python3
"""Stage-one data-only checker; invoke from a clean trusted checkout with -I -S.

This verifies supplied identities, not their authority. The caller must obtain the
base and synthetic merge SHAs from the event, and provision tools from trusted code.
"""
import sys

if not sys.flags.isolated or not sys.flags.no_site:
    sys.exit("trusted-data: invoke with python3 -I -S")

import argparse
import os
from pathlib import Path
import re
import stat
import subprocess


def fail(message):
    raise ValueError(message)


def run(*args, capture=False):
    # No shell startup files, Python environment imports, or optional git writes.
    env = dict(os.environ)
    for key in ("BASH_ENV", "ENV", "PYTHONPATH", "PYTHONHOME"):
        env.pop(key, None)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return subprocess.run(args, check=True, text=True, env=env,
                          stdout=subprocess.PIPE if capture else None).stdout


def git(root, *args):
    return run("git", "-c", "core.fsmonitor=false", "-C", str(root),
               *args, capture=True).strip()


def checkout(root, expected, label):
    if not re.fullmatch(r"[0-9a-f]{40}", expected):
        fail(f"{label}: expected a full lowercase commit SHA")
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root:
        fail(f"{label}: root must be the checkout top level")
    if git(root, "rev-parse", "HEAD") != expected:
        fail(f"{label}: HEAD does not match expected SHA")
    if git(root, "status", "--porcelain", "--untracked-files=all",
           "--ignored=matching"):
        fail(f"{label}: checkout must be clean, including ignored files")


def regular_tree(root):
    # find/jq/yq/shellcheck must never follow candidate links or block on FIFOs.
    # .git is checkout infrastructure, not candidate source (also a worktree file).
    for directory, dirs, files in os.walk(root, followlinks=False):
        if Path(directory) == root:
            dirs[:] = [name for name in dirs if name != ".git"]
            files = [name for name in files if name != ".git"]
        for name in dirs + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                fail(f"non-regular candidate path: {path.relative_to(root)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", required=True, type=Path)
    parser.add_argument("--trusted-sha", required=True)
    parser.add_argument("--candidate-sha", required=True)
    args = parser.parse_args()
    trusted = Path(__file__).resolve().parent.parent
    candidate = args.candidate_root.resolve(strict=True)
    if (trusted == candidate or trusted in candidate.parents
            or candidate in trusted.parents):
        fail("trusted and candidate roots must be distinct and non-nested")
    os.chdir(trusted)
    checkout(trusted, args.trusted_sha, "trusted")
    checkout(candidate, args.candidate_sha, "candidate")
    regular_tree(candidate)

    # Freeze expectations to the trusted tree. Never source candidate libraries,
    # run its resolver, or invoke its validators/tests/configuration.
    for relative in ("tests/fixtures/review-decision/v1/contract.json",
                     "tests/fixtures/review-decision/v1/corpus.json",
                     "skills/pro-gate/review-decision-v1.json"):
        if (trusted / relative).read_bytes() != (candidate / relative).read_bytes():
            fail(f"frozen metadata differs from trusted base: {relative}")

    run("bash", str(trusted / "scripts/validate-source.sh"), str(candidate))
    version = (candidate / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail("candidate VERSION must be a numeric major.minor.patch")
    # Deliberately no candidate tag lookup/skip: current notes are always checked.
    notes = candidate / "docs/release-notes" / f"v{version}.md"
    run("bash", str(trusted / "scripts/check-release-notes.sh"), str(notes))
    print(f"trusted-data OK: trusted={args.trusted_sha} candidate={args.candidate_sha}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"trusted-data: {error}")
