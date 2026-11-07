#!/usr/bin/env python3
"""Read-only CloudWatch summary of an EKS worker node group's CPU and burst-credit use.

Backs plans/ec2-worker-node-sizing.md. Queries the AWS/EC2 metrics by Auto Scaling
group name (the dimension survives node rolls, unlike InstanceId) and prints, per
day: average and maximum CPUUtilization, the lowest CPUCreditBalance, and the sum of
CPUCreditUsage and CPUSurplusCreditsCharged. It also prints the hourly CPU p95 and
p99 over the window. Nothing is written to AWS.

Usage:
    AWS_PROFILE=ac-ci-staging python3 -I scripts/ec2_worker_node_utilization.py \
        --asg eks-primary-... [--days 14] [--region us-west-1]

Use `aws autoscaling describe-auto-scaling-groups` to find the current ASG name, or
`aws cloudwatch list-metrics --namespace AWS/EC2 --metric-name CPUCreditBalance` for
the names of ASGs that have been deleted since (their metrics stay queryable).
"""

import argparse
import datetime as dt
import json
import subprocess
import sys


def get_stats(region, metric, asg, start, end, period, stats):
    cmd = [
        "aws",
        "cloudwatch",
        "get-metric-statistics",
        "--region",
        region,
        "--namespace",
        "AWS/EC2",
        "--metric-name",
        metric,
        "--dimensions",
        f"Name=AutoScalingGroupName,Value={asg}",
        "--start-time",
        start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "--end-time",
        end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "--period",
        str(period),
        "--statistics",
        *stats,
        "--output",
        "json",
    ]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    points = json.loads(out)["Datapoints"]
    return sorted(points, key=lambda p: p["Timestamp"])


def percentile(values, pct):
    if not values:
        return float("nan")
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(pct / 100 * (len(ordered) - 1))))
    return ordered[index]


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--asg", required=True, help="Auto Scaling group name")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--region", default="us-west-1")
    parser.add_argument(
        "--end",
        default=None,
        help="End of the window as an ISO UTC timestamp (default: now)",
    )
    args = parser.parse_args()

    end = (
        dt.datetime.fromisoformat(args.end).replace(tzinfo=dt.timezone.utc)
        if args.end
        else dt.datetime.now(dt.timezone.utc)
    )
    start = end - dt.timedelta(days=args.days)
    day = 86400
    hour = 3600

    cpu_daily = get_stats(
        args.region, "CPUUtilization", args.asg, start, end, day, ["Average", "Maximum"]
    )
    balance_daily = get_stats(
        args.region,
        "CPUCreditBalance",
        args.asg,
        start,
        end,
        day,
        ["Minimum", "Average"],
    )
    usage_daily = get_stats(
        args.region, "CPUCreditUsage", args.asg, start, end, day, ["Sum"]
    )
    surplus_daily = get_stats(
        args.region, "CPUSurplusCreditsCharged", args.asg, start, end, day, ["Sum"]
    )
    cpu_hourly = get_stats(
        args.region,
        "CPUUtilization",
        args.asg,
        start,
        end,
        hour,
        ["Average", "Maximum"],
    )

    def by_day(points):
        return {p["Timestamp"][:10]: p for p in points}

    bal = by_day(balance_daily)
    use = by_day(usage_daily)
    sur = by_day(surplus_daily)

    print(f"ASG: {args.asg}")
    print(
        f"Window: {start:%Y-%m-%d} to {end:%Y-%m-%d} UTC ({args.days} days), region {args.region}"
    )
    print()
    print(
        "day         cpu_avg%  cpu_max%  credit_bal_min  credit_bal_avg  credits_used  surplus_charged"
    )
    for p in cpu_daily:
        key = p["Timestamp"][:10]
        b = bal.get(key, {})
        print(
            f"{key}  {p['Average']:8.2f}  {p['Maximum']:8.2f}  "
            f"{b.get('Minimum', float('nan')):14.1f}  {b.get('Average', float('nan')):14.1f}  "
            f"{use.get(key, {}).get('Sum', float('nan')):12.1f}  "
            f"{sur.get(key, {}).get('Sum', float('nan')):15.1f}"
        )

    hourly_avg = [p["Average"] for p in cpu_hourly]
    hourly_max = [p["Maximum"] for p in cpu_hourly]
    print()
    print(f"hourly datapoints: {len(cpu_hourly)}")
    if hourly_avg:
        print(
            f"hourly average CPU: mean {sum(hourly_avg)/len(hourly_avg):.2f}%  "
            f"p95 {percentile(hourly_avg, 95):.2f}%  p99 {percentile(hourly_avg, 99):.2f}%  "
            f"max {max(hourly_avg):.2f}%"
        )
        print(
            f"hourly maximum CPU (5-min peaks): p95 {percentile(hourly_max, 95):.2f}%  "
            f"p99 {percentile(hourly_max, 99):.2f}%  max {max(hourly_max):.2f}%"
        )
        hours_over_20 = sum(1 for v in hourly_avg if v > 20)
        print(
            f"hours with average CPU above the 20% t-medium baseline: {hours_over_20}"
        )
    total_used = sum(p["Sum"] for p in usage_daily)
    total_surplus = sum(p["Sum"] for p in surplus_daily)
    print(
        f"credits used over window: {total_used:.1f}; surplus credits charged: {total_surplus:.1f}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
