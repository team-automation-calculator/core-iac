#!/usr/bin/env python3
"""Wait for GitHub commit statuses (for example Terraform Cloud runs) to leave "pending".

Usage:
    python3 -I scripts/wait_commit_status.py SHA [--filter Terraform] [--interval 30] [--timeout 1800]

Polls `gh api repos/<owner>/<repo>/commits/SHA/status` with the gh CLI (so it reuses the
gh login) and prints one line per status context each time its state changes. Exits 0 when
every matching context is in a terminal state (success, failure, error), 1 on timeout.
"""

import argparse
import json
import subprocess
import sys
import time

REPO = "team-automation-calculator/core-iac"
TERMINAL = {"success", "failure", "error"}


def fetch(sha: str) -> list[dict]:
    out = subprocess.run(
        ["gh", "api", f"repos/{REPO}/commits/{sha}/status"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["statuses"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sha")
    parser.add_argument(
        "--filter", default="Terraform", help="substring a context must contain"
    )
    parser.add_argument("--interval", type=int, default=30)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()

    seen: dict[str, str] = {}
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            statuses = [s for s in fetch(args.sha) if args.filter in s["context"]]
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as exc:
            print(f"poll error: {exc}", file=sys.stderr, flush=True)
            time.sleep(args.interval)
            continue
        for s in statuses:
            if seen.get(s["context"]) != s["state"]:
                seen[s["context"]] = s["state"]
                print(
                    f"{s['updated_at']} {s['context']} {s['state']} {s['target_url']}",
                    flush=True,
                )
        if statuses and all(s["state"] in TERMINAL for s in statuses):
            return 0
        time.sleep(args.interval)
    print("timeout waiting for statuses", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
