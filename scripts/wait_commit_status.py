#!/usr/bin/env python3
"""Wait for GitHub commit statuses (for example Terraform Cloud runs) to leave "pending".

Usage:
    python3 -I scripts/wait_commit_status.py SHA [--filter Terraform] [--interval 30] [--timeout 1800]
    python3 -I scripts/wait_commit_status.py MERGE_SHA --until-applied [--filter cluster_addons_layer]

Polls `gh api repos/<owner>/<repo>/commits/SHA/status` with the gh CLI (so it reuses the
gh login) and prints one line per status context each time its state or description
changes.

Default mode exits 0 when every matching context is in a terminal state (success, failure,
error), 1 on timeout. That suits a PR head, whose speculative plan ends at a "Terraform plan:"
success.

On a merge commit Terraform Cloud first posts `success` "Terraform plan: N to add, ..." when
the plan finishes, then `pending` "Terraform apply pending" while the apply waits in the queue
(or for a confirm), then `success` "Terraform apply: N added, ...". `--until-applied` keeps
waiting through the plan success: a context is done only at an apply success ("Terraform
apply: ..."), at "Terraform plan has no changes" (no apply follows), or at failure/error.
With `--until-applied` the exit code is 0 when every context applied or had no changes, 2 if
any ended in failure or error, and 1 on timeout. The timeout message names each context still
waiting; a workspace that needs a confirm in the UI (the global production workspaces) waits
there until a human confirms it.
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import time

logger = logging.getLogger(__name__)

REPO = "team-automation-calculator/core-iac"
TERMINAL = {"success", "failure", "error"}
FAILED = {"failure", "error"}
APPLIED_PREFIX = "Terraform apply:"
NO_CHANGES = "Terraform plan has no changes"


def fetch(sha: str) -> list[dict]:
    out = subprocess.run(
        ["gh", "api", f"repos/{REPO}/commits/{sha}/status"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["statuses"]


def is_done(status: dict, until_applied: bool) -> bool:
    """Whether a status needs no more waiting."""
    state = status["state"]
    if not until_applied:
        return state in TERMINAL
    if state in FAILED:
        return True
    if state != "success":
        return False
    description = status.get("description") or ""
    return description.startswith((APPLIED_PREFIX, NO_CHANGES))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("sha")
    parser.add_argument(
        "--filter", default="Terraform", help="substring a context must contain"
    )
    parser.add_argument("--interval", type=int, default=30)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument(
        "--until-applied",
        action="store_true",
        help="on a merge commit, wait past the plan success for the apply "
        '("Terraform apply: ...") or "Terraform plan has no changes"',
    )
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(levelname)s: %(message)s",
        stream=sys.stderr,
    )

    seen: dict[str, tuple[str, str]] = {}
    statuses: list[dict] = []
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            statuses = [s for s in fetch(args.sha) if args.filter in s["context"]]
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as exc:
            logger.warning("poll error: %s", exc)
            time.sleep(args.interval)
            continue
        for s in statuses:
            key = (s["state"], s.get("description") or "")
            if seen.get(s["context"]) != key:
                seen[s["context"]] = key
                print(
                    f"{s['updated_at']} {s['context']} {s['state']} "
                    f"{s['target_url']} {key[1]}".rstrip(),
                    flush=True,
                )
        if statuses and all(is_done(s, args.until_applied) for s in statuses):
            if args.until_applied and any(s["state"] in FAILED for s in statuses):
                return 2
            return 0
        time.sleep(args.interval)
    print("timeout waiting for statuses", flush=True)
    if not statuses:
        print(f"no status context matching {args.filter!r} yet", flush=True)
    for s in statuses:
        if not is_done(s, args.until_applied):
            print(
                f"still waiting: {s['context']} {s['state']} "
                f"{s.get('description') or ''}".rstrip(),
                flush=True,
            )
    return 1


if __name__ == "__main__":
    sys.exit(main())
