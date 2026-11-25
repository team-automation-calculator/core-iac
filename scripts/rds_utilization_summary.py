#!/usr/bin/env python3
"""Summarize CloudWatch utilization for the RDS instances in the current AWS account.

Read-only. Used for plans/rds-instance-sizing.md. Shells out to the AWS CLI so the
only requirement is a logged-in SSO profile (AWS_PROFILE=ac-ci-staging works for
the shared account; production-profile reads are denied here).

Usage:
    AWS_PROFILE=ac-ci-staging python3 -I scripts/rds_utilization_summary.py [--days 14] [--period 3600]

For every DB instance it prints one row per metric with the 14-day average of the
hourly averages, the overall maximum of the hourly maxima, and the minimum of the
hourly minima (the minimum matters for FreeableMemory, BurstBalance,
CPUCreditBalance and FreeStorageSpace, where the low-water mark is the risk).
"""

import argparse
import datetime as dt
import json
import subprocess
import sys

METRICS = [
    # (metric name, unit label, divisor for display)
    ("CPUUtilization", "%", 1),
    ("CPUCreditBalance", "credits", 1),
    ("CPUCreditUsage", "credits/5min", 1),
    ("CPUSurplusCreditsCharged", "credits", 1),
    ("FreeableMemory", "MiB", 1024 * 1024),
    ("SwapUsage", "MiB", 1024 * 1024),
    ("DatabaseConnections", "conns", 1),
    ("FreeStorageSpace", "GiB", 1024 * 1024 * 1024),
    ("BurstBalance", "%", 1),
    ("ReadIOPS", "iops", 1),
    ("WriteIOPS", "iops", 1),
    ("ReadThroughput", "KiB/s", 1024),
    ("WriteThroughput", "KiB/s", 1024),
    ("ReadLatency", "ms", 0.001),
    ("WriteLatency", "ms", 0.001),
]


def aws(args, region):
    cmd = ["aws", "--region", region, "--output", "json"] + args
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}\n{result.stderr.strip()}")
    return json.loads(result.stdout)


def instances(region):
    data = aws(["rds", "describe-db-instances"], region)
    return [
        (
            d["DBInstanceIdentifier"],
            d["DBInstanceClass"],
            d["StorageType"],
            d["AllocatedStorage"],
            d["MultiAZ"],
            d["BackupRetentionPeriod"],
            d["EngineVersion"],
        )
        for d in data["DBInstances"]
    ]


def metric(region, instance_id, name, start, end, period):
    try:
        data = aws(
            [
                "cloudwatch",
                "get-metric-statistics",
                "--namespace",
                "AWS/RDS",
                "--metric-name",
                name,
                "--dimensions",
                f"Name=DBInstanceIdentifier,Value={instance_id}",
                "--start-time",
                start.isoformat(),
                "--end-time",
                end.isoformat(),
                "--period",
                str(period),
                "--statistics",
                "Average",
                "Maximum",
                "Minimum",
            ],
            region,
        )
    except RuntimeError as exc:
        return None, str(exc).splitlines()[-1]
    points = data.get("Datapoints", [])
    if not points:
        return None, "no datapoints"
    avg = sum(p["Average"] for p in points) / len(points)
    mx = max(p["Maximum"] for p in points)
    mn = min(p["Minimum"] for p in points)
    return (avg, mx, mn, len(points)), None


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--region", default="us-west-1")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--period", type=int, default=3600)
    args = parser.parse_args()

    end = dt.datetime.now(dt.UTC).replace(microsecond=0)
    start = end - dt.timedelta(days=args.days)
    print(f"Window: {start.isoformat()} to {end.isoformat()} (period {args.period}s)\n")

    for inst in instances(args.region):
        instance_id, klass, storage, alloc, multi_az, retention, engine = inst
        print(
            f"== {instance_id}: {klass}, {storage} {alloc} GiB, multi_az={multi_az}, "
            f"backup_retention={retention}, postgres {engine}"
        )
        print(
            f"{'metric':26} {'unit':12} {'avg':>12} {'max':>12} {'min':>12} {'pts':>5}"
        )
        for name, unit, divisor in METRICS:
            stats, err = metric(args.region, instance_id, name, start, end, args.period)
            if err or stats is None:
                print(f"{name:26} {unit:12} {err or 'no data'}")
                continue
            avg, mx, mn, n = stats
            print(
                f"{name:26} {unit:12} {avg / divisor:12.2f} {mx / divisor:12.2f} "
                f"{mn / divisor:12.2f} {n:5d}"
            )
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
