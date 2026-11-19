"""Tests for breaches, replay, unsupported_reason, main and parse_time in scripts/alb_alarm_window.py."""

import datetime as dt
import sys

import alb_alarm_window
import pytest
from alb_alarm_window import breaches, parse_time, replay, unsupported_reason


def alarm(op="GreaterThanThreshold", threshold=0.0, periods=1, **extra):
    return {
        "ComparisonOperator": op,
        "Threshold": threshold,
        "EvaluationPeriods": periods,
        **extra,
    }


# breaches


@pytest.mark.parametrize(
    ("op", "below", "equal", "above"),
    [
        ("GreaterThanThreshold", False, False, True),
        ("GreaterThanOrEqualToThreshold", False, True, True),
        ("LessThanThreshold", True, False, False),
        ("LessThanOrEqualToThreshold", True, True, False),
    ],
)
def test_breaches_comparison_operators(op, below, equal, above):
    rule = alarm(op=op, threshold=5.0)
    assert breaches(4.0, rule) is below
    assert breaches(5.0, rule) is equal
    assert breaches(6.0, rule) is above


@pytest.mark.parametrize(
    ("treat", "expected"),
    [
        ("notBreaching", False),
        ("breaching", True),
        ("missing", False),
        ("ignore", False),
        (None, False),
    ],
)
def test_breaches_missing_datapoint(treat, expected):
    rule = alarm(threshold=-1.0)
    if treat is not None:
        rule["TreatMissingData"] = treat
    assert breaches(None, rule) is expected


def test_breaches_zero_is_a_value_not_missing():
    assert breaches(0.0, alarm(op="LessThanThreshold", threshold=1.0)) is True


ANOMALY_OPERATORS = [
    "GreaterThanUpperThreshold",
    "LessThanLowerThreshold",
    "LessThanLowerOrGreaterThanUpperThreshold",
]


@pytest.mark.parametrize("op", ANOMALY_OPERATORS)
def test_breaches_anomaly_operator_raises_value_error(op):
    rule = {"ComparisonOperator": op, "EvaluationPeriods": 1}
    with pytest.raises(ValueError, match=op):
        breaches(1.0, rule)


# unsupported_reason


def test_unsupported_reason_none_for_static_threshold_alarm():
    assert unsupported_reason(alarm(MetricName="HTTPCode_ELB_5XX_Count")) is None


@pytest.mark.parametrize("op", ANOMALY_OPERATORS)
def test_unsupported_reason_anomaly_operator(op):
    rule = {"ComparisonOperator": op, "ThresholdMetricId": "ad1", "Metrics": []}
    assert op in unsupported_reason(rule)


def test_unsupported_reason_metric_math():
    rule = alarm(Metrics=[{"Id": "e1", "Expression": "m1 + m2"}])
    assert "metric math" in unsupported_reason(rule)


# replay


def minutes(count):
    start = dt.datetime(2026, 11, 7, 16, 0, tzinfo=dt.UTC)
    return [start + dt.timedelta(minutes=i) for i in range(count)]


def series_of(window, values):
    return {m: v for m, v in zip(window, values) if v is not None}


def test_replay_single_period_alarm_and_recovery():
    window = minutes(5)
    series = series_of(window, [0, 3, 2, 0, 0])
    assert list(replay(alarm(), series, window)) == [
        (window[1], "ALARM"),
        (window[3], "OK"),
    ]


def test_replay_needs_consecutive_breaches():
    window = minutes(6)
    rule = alarm(periods=2)
    # One-minute blips at 1 and 3 never fill a two-minute window.
    assert list(replay(rule, series_of(window, [0, 1, 0, 1, 0, 0]), window)) == []
    assert list(replay(rule, series_of(window, [0, 1, 1, 0, 0, 0]), window)) == [
        (window[2], "ALARM"),
        (window[3], "OK"),
    ]


def test_replay_skips_minutes_before_a_full_window():
    window = minutes(3)
    rule = alarm(periods=3)
    # Breaching from the first minute, but the first full window ends at minute 2.
    assert list(replay(rule, series_of(window, [1, 1, 1]), window)) == [
        (window[2], "ALARM")
    ]


def test_replay_window_shorter_than_periods_yields_nothing():
    window = minutes(2)
    assert list(replay(alarm(periods=3), series_of(window, [1, 1]), window)) == []


def test_replay_datapoints_to_alarm_m_of_n():
    window = minutes(5)
    rule = alarm(periods=3, DatapointsToAlarm=2)
    series = series_of(window, [1, 0, 1, 0, 0])
    assert list(replay(rule, series, window)) == [
        (window[2], "ALARM"),
        (window[3], "OK"),
    ]


def test_replay_without_datapoints_to_alarm_needs_all_periods():
    window = minutes(4)
    rule = alarm(periods=2)
    assert list(replay(rule, series_of(window, [1, 0, 1, 1]), window)) == [
        (window[3], "ALARM")
    ]


def test_replay_missing_minutes_are_not_breaching():
    window = minutes(4)
    rule = alarm(periods=2, TreatMissingData="notBreaching")
    # Sparse metric: datapoints only at 0 and 2, gap at 1, so no two in a row.
    assert list(replay(rule, series_of(window, [5, None, 5, None]), window)) == []


def test_replay_missing_minutes_can_breach():
    window = minutes(3)
    rule = alarm(periods=2, TreatMissingData="breaching")
    assert list(replay(rule, {}, window)) == [(window[1], "ALARM")]


def test_replay_less_than_alarm_like_healthy_hosts():
    window = minutes(4)
    rule = alarm(op="LessThanThreshold", threshold=1.0, periods=1)
    series = series_of(window, [1, 0, 0, 1])
    assert list(replay(rule, series, window)) == [
        (window[1], "ALARM"),
        (window[3], "OK"),
    ]


def test_replay_empty_window():
    assert list(replay(alarm(), {}, [])) == []


# main


def test_main_skips_anomaly_alarm_with_warning(monkeypatch, capsys, caplog):
    dims = [{"Name": "LoadBalancer", "Value": "app/ac-app-production/abc"}]
    static = alarm(
        AlarmName="ac-app-production-alb-5xx-errors",
        MetricName="HTTPCode_ELB_5XX_Count",
        Namespace="AWS/ApplicationELB",
        Dimensions=dims,
        Statistic="Sum",
        Period=60,
        TreatMissingData="notBreaching",
    )
    anomaly = {
        "AlarmName": "ac-app-production-anomaly",
        "ComparisonOperator": "GreaterThanUpperThreshold",
        "EvaluationPeriods": 1,
        "ThresholdMetricId": "ad1",
        "Metrics": [{"Id": "ad1", "Expression": "ANOMALY_DETECTION_BAND(m1, 2)"}],
    }
    monkeypatch.setattr(
        alb_alarm_window, "describe_alarms", lambda env, region: [anomaly, static]
    )
    monkeypatch.setattr(alb_alarm_window, "metric_series", lambda *a: {})
    monkeypatch.setattr(alb_alarm_window, "target_group_dimensions", lambda *a: None)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "alb_alarm_window.py",
            "--start",
            "2026-11-07T16:00:00Z",
            "--end",
            "2026-11-07T16:05:00Z",
        ],
    )

    alb_alarm_window.main()

    out = capsys.readouterr().out
    assert "alb-5xx-errors" in out
    assert "anomaly" not in out
    warnings = [r.getMessage() for r in caplog.records if r.levelname == "WARNING"]
    assert any(
        "ac-app-production-anomaly" in m and "GreaterThanUpperThreshold" in m
        for m in warnings
    )


# parse_time


def test_parse_time_is_utc_aware():
    parsed = parse_time("2026-11-07T16:25:00Z")
    assert parsed == dt.datetime(2026, 11, 7, 16, 25, tzinfo=dt.UTC)
    assert parsed.utcoffset() == dt.timedelta(0)


@pytest.mark.parametrize(
    "text",
    [
        "2026-11-07T16:25:00",
        "2026-11-07T16:25:00+00:00",
        "2026-11-07T16:25:00.000Z",
        "2026-11-07 16:25:00Z",
        "2026-11-07",
        "",
    ],
)
def test_parse_time_rejects_other_formats(text):
    with pytest.raises(ValueError):
        parse_time(text)
