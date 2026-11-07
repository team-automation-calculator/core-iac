#!/usr/bin/env python3
"""Poll an environment's RDS instances read-only and log every status change.

Used to time the outage RDS documents when backup_retention_period moves between 0 and a
non-zero value (the instance goes `modifying` -> `backing-up` -> `available`), and more
generally to see when an apply reaches the instance.

    python3 -I scripts/rds_status_poll.py staging tmp/414/rds-poll.log
    python3 -I scripts/rds_status_poll.py staging tmp/414/rds-poll.log --minutes 45 --interval 10

Writes one line per change (and one at start) to the log and stdout:
    2026-11-04T20:31:00Z ac-app-staging available 0 05:45-06:15

Only `aws rds describe-db-instances` is called, under the environment's `-ro` profile.
"""

import argparse
import datetime as dt
import json
import subprocess
import sys
import time

PROFILES = {"staging": "ac-ci-staging-ro", "production": "ac-ci-prod-ro"}


def describe(profile: str, region: str) -> str:
    cmd = [
        "aws", "rds", "describe-db-instances",
        "--region", region, "--profile", profile, "--output", "json",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as exc:  # e.g. `aws` not on PATH in a detached shell; keep polling
        return f"error: {exc}"
    if proc.returncode != 0:
        return f"error: {proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else proc.returncode}"
    try:
        instances = json.loads(proc.stdout)["DBInstances"]
    except (ValueError, KeyError) as exc:
        return f"error: unparseable describe-db-instances output ({exc})"
    rows = []
    for inst in instances:
        rows.append(
            f"{inst['DBInstanceIdentifier']} {inst['DBInstanceStatus']} "
            f"retention={inst['BackupRetentionPeriod']} window={inst.get('PreferredBackupWindow')} "
            f"latest_restorable={inst.get('LatestRestorableTime')}"
        )
    return "; ".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("env", choices=sorted(PROFILES))
    ap.add_argument("log")
    ap.add_argument("--minutes", type=float, default=45)
    ap.add_argument("--interval", type=float, default=10)
    ap.add_argument("--region", default="us-west-1")
    args = ap.parse_args()

    profile = PROFILES[args.env]
    deadline = time.monotonic() + args.minutes * 60
    prev = None
    with open(args.log, "a") as log:
        while time.monotonic() < deadline:
            cur = describe(profile, args.region)
            if cur != prev:
                line = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {cur}"
                print(line, flush=True)
                log.write(line + "\n")
                log.flush()
                prev = cur
            time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
