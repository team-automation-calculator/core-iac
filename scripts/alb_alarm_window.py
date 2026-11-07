#!/usr/bin/env python3
"""Read-only replay of the cluster-addons CloudWatch alarms over an ALB metrics window.

Answers "which alarm emails would have gone out during this deployment?" without
depending on the SNS subscription having been confirmed at the time. It reads the
`ac-app-<env>-*` alarm definitions with `describe-alarms`, pulls the AWS/ApplicationELB
metrics they evaluate at 60 s granularity for the window, prints every minute in which
any of them was non-zero, and re-applies each alarm's rule (statistic, comparison,
threshold, consecutive evaluation periods) to say when it would have entered ALARM
and returned to OK. Nothing is written to AWS.

Usage:
    AWS_PROFILE=ac-ci-staging-ro python3 -I scripts/alb_alarm_window.py \
        --start 2026-11-07T16:25:00Z --end 2026-11-07T17:45:00Z \
        [--env production] [--region us-west-1]

Both staging and production live in one account, so the staging read-only profile can
read the production alarms and metrics (CloudWatch reads are account-level).

The replay is an approximation. It treats a minute with no datapoint as not breaching,
exactly as `TreatMissingData = notBreaching` says, but the live alarm evaluates the most
recent *available* datapoints and looks back further when a sparse metric (the 5xx
counts are only published for minutes with errors) has gaps. On 2026-11-04 the live
`alb-5xx-errors` alarm fired on two breaching minutes six minutes apart that this replay
reports as separate single-minute blips. Treat `aws cloudwatch describe-alarm-history`
as the authority for what actually transitioned; use this script to see the metric values
behind a transition, or the near misses when nothing fired.
"""

DESCRIPTION = "Read-only replay of the cluster-addons CloudWatch alarms over an ALB metrics window."

import argparse
import datetime as dt
import json
import subprocess
import sys

WINDOW_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

# Metrics shown in the per-minute table in addition to the ones the alarms evaluate.
CONTEXT_METRICS = [
    ("RequestCount", "Sum"),
    ("HealthyHostCount", "Minimum"),
    # Shown with the target group dimensions AWS actually publishes, unlike the
    # unhealthy-hosts alarm itself (see the WARNING printed when it lacks them).
    ("UnHealthyHostCount", "Maximum"),
]


def aws(args, region):
    cmd = ["aws", "--region", region, "--output", "json", *args]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.exit(f"aws {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def describe_alarms(env, region):
    data = aws(
        ["cloudwatch", "describe-alarms", "--alarm-name-prefix", f"ac-app-{env}-"],
        region,
    )
    alarms = data["MetricAlarms"]
    if not alarms:
        sys.exit(f"no alarms named ac-app-{env}-* in {region}")
    return alarms


def target_group_dimensions(load_balancer, region):
    """Dimensions of the target-group-level host count metrics for one ALB.

    UnHealthyHostCount and HealthyHostCount are only published per target group
    (TargetGroup + LoadBalancer, with or without AvailabilityZone), never for the
    load balancer alone. Returns the first TargetGroup+LoadBalancer pair found, or
    None when the ALB has no target group metrics.
    """
    data = aws(
        [
            "cloudwatch",
            "list-metrics",
            "--namespace",
            "AWS/ApplicationELB",
            "--metric-name",
            "HealthyHostCount",
            "--dimensions",
            f"Name=LoadBalancer,Value={load_balancer}",
        ],
        region,
    )
    for metric in data["Metrics"]:
        names = sorted(d["Name"] for d in metric["Dimensions"])
        if names == ["LoadBalancer", "TargetGroup"]:
            return metric["Dimensions"]
    return None


def metric_series(alarm_like, start, end, region):
    """Return {minute: value} for one metric/statistic over the window."""
    stat = alarm_like.get("Statistic")
    ext = alarm_like.get("ExtendedStatistic")
    args = [
        "cloudwatch",
        "get-metric-statistics",
        "--namespace",
        alarm_like["Namespace"],
        "--metric-name",
        alarm_like["MetricName"],
        "--dimensions",
        *[f"Name={d['Name']},Value={d['Value']}" for d in alarm_like["Dimensions"]],
        "--start-time",
        start.strftime(WINDOW_FORMAT),
        "--end-time",
        end.strftime(WINDOW_FORMAT),
        "--period",
        "60",
    ]
    if ext:
        args += ["--extended-statistics", ext]
    else:
        args += ["--statistics", stat]
    points = aws(args, region)["Datapoints"]
    series = {}
    for point in points:
        when = dt.datetime.fromisoformat(point["Timestamp"])
        value = point["ExtendedStatistics"][ext] if ext else point[stat]
        series[when] = value
    return series


def breaches(value, alarm):
    op = alarm["ComparisonOperator"]
    threshold = alarm["Threshold"]
    if value is None:
        # TreatMissingData=notBreaching on every alarm in cloudwatch_alarms.tf.
        return alarm.get("TreatMissingData") == "breaching"
    return {
        "GreaterThanThreshold": value > threshold,
        "GreaterThanOrEqualToThreshold": value >= threshold,
        "LessThanThreshold": value < threshold,
        "LessThanOrEqualToThreshold": value <= threshold,
    }[op]


def replay(alarm, series, minutes):
    """Yield (minute, 'ALARM'|'OK') transitions by re-applying the alarm's rule."""
    periods = alarm["EvaluationPeriods"]
    datapoints_to_alarm = alarm.get("DatapointsToAlarm") or periods
    state = "OK"
    for index, minute in enumerate(minutes):
        recent = minutes[max(0, index - periods + 1) : index + 1]
        if len(recent) < periods:
            continue
        breaching = sum(1 for m in recent if breaches(series.get(m), alarm))
        if state == "OK" and breaching >= datapoints_to_alarm:
            state = "ALARM"
            yield minute, state
        elif state == "ALARM" and breaching < datapoints_to_alarm:
            state = "OK"
            yield minute, state


def parse_time(text):
    return dt.datetime.strptime(text, WINDOW_FORMAT).replace(tzinfo=dt.UTC)


def main():
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument(
        "--start", required=True, type=parse_time, help="UTC, e.g. 2026-11-07T16:25:00Z"
    )
    parser.add_argument("--end", required=True, type=parse_time, help="UTC, exclusive")
    parser.add_argument("--env", default="production")
    parser.add_argument("--region", default="us-west-1")
    args = parser.parse_args()

    alarms = describe_alarms(args.env, args.region)
    dims = alarms[0]["Dimensions"]
    namespace = alarms[0]["Namespace"]

    columns = []
    for alarm in alarms:
        label = alarm["AlarmName"].replace(f"ac-app-{args.env}-", "")
        columns.append(
            (label, metric_series(alarm, args.start, args.end, args.region), alarm)
        )
    host_dims = target_group_dimensions(dims[0]["Value"], args.region)
    for metric, stat in CONTEXT_METRICS:
        use_dims = host_dims if metric.endswith("HostCount") and host_dims else dims
        fake = {
            "Namespace": namespace,
            "MetricName": metric,
            "Dimensions": use_dims,
            "Statistic": stat,
        }
        columns.append(
            (
                f"{metric}/{stat}",
                metric_series(fake, args.start, args.end, args.region),
                None,
            )
        )

    for alarm in alarms:
        if alarm["MetricName"].endswith("HostCount") and all(
            d["Name"] != "TargetGroup" for d in alarm["Dimensions"]
        ):
            print(
                f"WARNING: {alarm['AlarmName']} evaluates {alarm['MetricName']} with only the LoadBalancer "
                "dimension; AWS publishes that metric per target group, so this alarm never receives "
                "data and cannot fire. Check its StateReason with describe-alarms.",
                file=sys.stderr,
            )

    minutes = []
    minute = args.start
    while minute < args.end:
        minutes.append(minute)
        minute += dt.timedelta(minutes=1)

    print(f"Alarms for {args.env} on {dims[0]['Value']}:")
    for label, _, alarm in columns:
        if alarm is None:
            continue
        stat = alarm.get("ExtendedStatistic") or alarm["Statistic"]
        print(
            f"  {label:<20} {alarm['MetricName']} {stat} {alarm['ComparisonOperator']} "
            f"{alarm['Threshold']} for {alarm['EvaluationPeriods']} x {alarm['Period']}s, "
            f"missing={alarm['TreatMissingData']}"
        )

    print()
    print("Minutes with any non-zero alarm metric (UTC):")
    header = f"{'minute':<17}" + "".join(f"{label[:20]:>22}" for label, _, _ in columns)
    print(header)
    shown = 0
    for minute in minutes:
        alarm_values = [
            series.get(minute) for _, series, alarm in columns if alarm is not None
        ]
        if not any(v for v in alarm_values):
            continue
        shown += 1
        row = f"{minute.strftime('%m-%d %H:%M'):<17}"
        for _, series, _ in columns:
            value = series.get(minute)
            row += f"{'-' if value is None else round(value, 3):>22}"
        print(row)
    if shown == 0:
        print("  (none: every alarm metric was zero or missing for the whole window)")

    print()
    print("Replayed alarm transitions (each would have published to the SNS topic):")
    any_transition = False
    for label, series, alarm in columns:
        if alarm is None:
            continue
        for minute, state in replay(alarm, series, minutes):
            any_transition = True
            print(f"  {minute.strftime('%Y-%m-%d %H:%M')}Z  {label:<20} -> {state}")
    if not any_transition:
        print("  (none: no alarm would have left OK in this window)")


if __name__ == "__main__":
    main()
