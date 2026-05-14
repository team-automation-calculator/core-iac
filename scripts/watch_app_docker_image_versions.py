#!/usr/bin/env python3
"""Watch Docker Hub for a new app image tag and open a bump PR when one appears.

Snapshots the current set of tags on Docker Hub, then polls every minute for
10 minutes. If a new tag (one not present in the initial snapshot) appears,
invokes `bump_app_docker_image_version_branch.sh` with that version to create
the branch, commit, push, and open a PR bumping all envs.

Designed for local operator use. Standard library only.

Assumes the caller is on the `main` branch with a clean working tree; the
bump script branches off whatever HEAD is at when it runs.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

IMAGE_REPO = "automationcalculationsci/automation-calculator"
TAGS_URL = (
    f"https://hub.docker.com/v2/repositories/{IMAGE_REPO}/tags/"
    "?page_size=25&ordering=last_updated"
)
HTTP_TIMEOUT_SECONDS = 15
POLL_INTERVAL_SECONDS = 60
POLL_DURATION_SECONDS = 600
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+-\d+$")
BUMP_SCRIPT = Path(__file__).resolve().parent / "bump_app_docker_image_version_branch.sh"


def fetch_version_tags() -> list[dict]:
    with urllib.request.urlopen(TAGS_URL, timeout=HTTP_TIMEOUT_SECONDS) as response:
        data = json.load(response)
    return [t for t in data.get("results", []) if VERSION_RE.match(t["name"])]


def run_bump(version: str) -> int:
    print(f"Invoking {BUMP_SCRIPT.name} {version}")
    result = subprocess.run([str(BUMP_SCRIPT), version], cwd=BUMP_SCRIPT.parent)
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--interval",
        type=int,
        default=POLL_INTERVAL_SECONDS,
        help=f"Seconds between polls (default: {POLL_INTERVAL_SECONDS})",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=POLL_DURATION_SECONDS,
        help=f"Total polling window in seconds (default: {POLL_DURATION_SECONDS})",
    )
    args = parser.parse_args()

    print(
        f"Polling {IMAGE_REPO} every {args.interval}s for up to {args.duration}s, "
        f"looking for new version tags matching {VERSION_RE.pattern!r}"
    )
    baseline = fetch_version_tags()
    baseline_names = {t["name"] for t in baseline}
    if baseline:
        latest = max(baseline, key=lambda t: t["last_updated"])
        print(
            f"Baseline: {len(baseline_names)} tags, "
            f"newest={latest['name']} @ {latest['last_updated']}"
        )
    else:
        print("Baseline: no version tags found")

    deadline = time.monotonic() + args.duration
    while time.monotonic() < deadline:
        time.sleep(args.interval)
        try:
            current = fetch_version_tags()
        except urllib.error.URLError as exc:
            print(f"Fetch failed: {exc}; retrying next interval")
            continue
        new_tags = [t for t in current if t["name"] not in baseline_names]
        if new_tags:
            target = max(new_tags, key=lambda t: t["last_updated"])
            print(
                f"New tag detected: {target['name']} @ {target['last_updated']} "
                f"({len(new_tags)} new tag(s) total)"
            )
            return run_bump(target["name"])
        remaining = int(deadline - time.monotonic())
        print(f"No new tags; {remaining}s remaining")

    print("No new tags appeared within polling window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
