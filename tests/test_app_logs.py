"""Tests for the parsing, formatting and command building in scripts/app_logs.py."""

import argparse
import datetime as dt

import app_logs
import pytest
from app_logs import (
    filter_command,
    format_bytes,
    format_event,
    format_query_rows,
    format_time,
    parse_duration,
    parse_time,
    window,
)

NOW = dt.datetime(2026, 11, 24, 23, 30, tzinfo=dt.UTC)


class FakeAws:
    """Stands in for the aws CLI: returns queued outputs and records the calls."""

    def __init__(self, *outputs):
        self.outputs = list(outputs)
        self.calls = []

    def __call__(self, args):
        self.calls.append(args)
        return self.outputs.pop(0)


def run_main(monkeypatch, fake, argv):
    monkeypatch.setattr(app_logs, "aws", lambda profile, region, args: fake(args))
    return app_logs.main(argv)


# parse_duration, parse_time, window


@pytest.mark.parametrize(
    ("text", "seconds"),
    [("90s", 90), ("15m", 900), ("2h", 7200), ("7d", 604800)],
)
def test_parse_duration(text, seconds):
    assert parse_duration(text) == dt.timedelta(seconds=seconds)


@pytest.mark.parametrize("text", ["", "15", "m", "1.5h", "2w", "-5m"])
def test_parse_duration_rejects(text):
    with pytest.raises(argparse.ArgumentTypeError):
        parse_duration(text)


def test_parse_time_z_suffix_and_naive_are_utc():
    expected = dt.datetime(2026, 11, 24, 23, 0, tzinfo=dt.UTC)
    assert parse_time("2026-11-24T23:00:00Z") == expected
    assert parse_time("2026-11-24T23:00:00") == expected


def test_parse_time_converts_offsets_to_utc():
    assert parse_time("2026-11-24T15:00:00-08:00") == dt.datetime(
        2026, 11, 24, 23, 0, tzinfo=dt.UTC
    )


def test_parse_time_rejects_garbage():
    with pytest.raises(argparse.ArgumentTypeError):
        parse_time("yesterday")


def test_window_defaults_to_the_last_since():
    assert window(dt.timedelta(minutes=15), None, None, NOW) == (
        NOW - dt.timedelta(minutes=15),
        NOW,
    )


def test_window_explicit_start_and_end_win():
    start = NOW - dt.timedelta(hours=3)
    end = NOW - dt.timedelta(hours=2)
    assert window(dt.timedelta(minutes=15), start, end, NOW) == (start, end)


def test_window_end_only_counts_since_back_from_end():
    end = NOW - dt.timedelta(hours=2)
    assert window(dt.timedelta(minutes=30), None, end, NOW) == (
        end - dt.timedelta(minutes=30),
        end,
    )


def test_window_rejects_start_after_end():
    with pytest.raises(ValueError, match="not before"):
        window(dt.timedelta(minutes=15), NOW, NOW - dt.timedelta(hours=1), NOW)


# formatting


def test_format_time_keeps_milliseconds():
    assert format_time(1795562734975) == "2026-11-24T23:25:34.975Z"


def test_format_event_is_time_stream_message():
    event = {
        "timestamp": 1795562734975,
        "logStreamName": "app-automation-calculator-c756b595-bsgnm",
        "message": 'I, [2026-11-24T23:25:34.975108 #1]  INFO -- : Started GET "/"\n',
    }
    assert format_event(event) == (
        "2026-11-24T23:25:34.975Z app-automation-calculator-c756b595-bsgnm "
        'I, [2026-11-24T23:25:34.975108 #1]  INFO -- : Started GET "/"'
    )


def test_format_query_rows_drops_ptr():
    results = [
        [
            {"field": "bin(1h)", "value": "2026-11-24 23:00:00.000"},
            {"field": "count()", "value": "42"},
            {"field": "@ptr", "value": "opaque"},
        ]
    ]
    assert format_query_rows(results) == ["bin(1h)=2026-11-24 23:00:00.000 count()=42"]


@pytest.mark.parametrize(
    ("count", "text"),
    [
        (0, "0 B"),
        (1023, "1023 B"),
        (1024, "1.0 KB"),
        (87_031_808, "83.0 MB"),
        (5 * 1024**3, "5.0 GB"),
        (5000 * 1024**3, "5000.0 GB"),
    ],
)
def test_format_bytes(count, text):
    assert format_bytes(count) == text


# filter_command


def test_filter_command_minimal():
    start = NOW - dt.timedelta(minutes=15)
    assert filter_command("/ac/staging/app", start, NOW, None, None, 1000) == [
        "logs",
        "filter-log-events",
        "--log-group-name",
        "/ac/staging/app",
        "--start-time",
        str(int(start.timestamp() * 1000)),
        "--end-time",
        str(int(NOW.timestamp() * 1000)),
        "--max-items",
        "1000",
    ]


def test_filter_command_adds_pattern_and_stream_prefix():
    cmd = filter_command(
        "/ac/staging/app", NOW - dt.timedelta(hours=1), NOW, '"Completed 5"', "app-x", 5
    )
    assert cmd[-4:] == [
        "--filter-pattern",
        '"Completed 5"',
        "--log-stream-name-prefix",
        "app-x",
    ]


# commands, with the aws CLI faked


def test_tail_prints_events_and_reads_the_envs_group(monkeypatch, capsys):
    fake = FakeAws(
        {
            "events": [
                {
                    "timestamp": 1795562734975,
                    "logStreamName": "app-a",
                    "message": "one",
                },
                {
                    "timestamp": 1795562735000,
                    "logStreamName": "app-a",
                    "message": "two",
                },
            ]
        }
    )
    assert run_main(monkeypatch, fake, ["tail", "staging", "--since", "1h"]) == 0
    assert capsys.readouterr().out.splitlines() == [
        "2026-11-24T23:25:34.975Z app-a one",
        "2026-11-24T23:25:35.000Z app-a two",
    ]
    call = fake.calls[0]
    assert call[call.index("--log-group-name") + 1] == "/ac/staging/app"
    assert "--filter-pattern" not in call


def test_errors_uses_the_error_pattern(monkeypatch):
    fake = FakeAws({"events": []})
    assert run_main(monkeypatch, fake, ["errors", "production"]) == 0
    call = fake.calls[0]
    assert call[call.index("--log-group-name") + 1] == "/ac/production/app"
    assert call[call.index("--filter-pattern") + 1] == app_logs.ERROR_PATTERN


def test_profile_defaults_to_the_read_only_profile(monkeypatch):
    seen = []

    def fake_aws(profile, region, args):
        seen.append((profile, region))
        return {"logStreams": []}

    monkeypatch.setattr(app_logs, "aws", fake_aws)
    assert app_logs.main(["streams", "production"]) == 0
    assert (
        app_logs.main(["streams", "staging", "--profile", "infra-eng-staging-ro"]) == 0
    )
    assert seen == [
        ("ac-ci-prod-ro", "us-west-1"),
        ("infra-eng-staging-ro", "us-west-1"),
    ]


def test_aws_failure_is_reported_not_raised(monkeypatch, caplog):
    def fake_aws(profile, region, args):
        raise app_logs.AwsError("ResourceNotFoundException: no such group")

    monkeypatch.setattr(app_logs, "aws", fake_aws)
    assert app_logs.main(["streams", "staging"]) == 1
    assert "ResourceNotFoundException" in caplog.text


def test_query_polls_until_complete(capsys):
    fake = FakeAws(
        {"queryId": "q-1"},
        {"status": "Running"},
        {
            "status": "Complete",
            "results": [[{"field": "count()", "value": "3"}]],
            "statistics": {"bytesScanned": 2048.0, "recordsScanned": 12.0},
        },
    )
    args = app_logs.build_parser().parse_args(
        ["query", "staging", "stats count()", "--since", "1h"]
    )
    assert app_logs.cmd_query(args, fake, sleep=lambda seconds: None) == 0
    assert capsys.readouterr().out.splitlines() == ["count()=3"]
    assert fake.calls[0][-1] == "stats count()"
    assert fake.calls[1] == ["logs", "get-query-results", "--query-id", "q-1"]
    assert len(fake.calls) == 3


def test_query_failure_returns_one(capsys):
    fake = FakeAws({"queryId": "q-1"}, {"status": "Failed"})
    args = app_logs.build_parser().parse_args(["query", "staging", "bad"])
    assert app_logs.cmd_query(args, fake, sleep=lambda seconds: None) == 1
    assert capsys.readouterr().out == ""


def test_volume_prints_days_in_order(monkeypatch, capsys):
    fake = FakeAws(
        {
            "Datapoints": [
                {"Timestamp": "2026-11-24T00:00:00+00:00", "Sum": 87_031_808.0},
                {"Timestamp": "2026-11-23T00:00:00+00:00", "Sum": 1024.0},
            ]
        }
    )
    assert run_main(monkeypatch, fake, ["volume", "production", "--days", "2"]) == 0
    assert capsys.readouterr().out.splitlines() == [
        "2026-11-23 1.0 KB",
        "2026-11-24 83.0 MB",
    ]
    call = fake.calls[0]
    assert "Name=LogGroupName,Value=/ac/production/app" in call


def test_volume_window_is_whole_utc_days_including_today(monkeypatch):
    fake = FakeAws({"Datapoints": []})
    before = dt.datetime.now(dt.UTC)
    assert run_main(monkeypatch, fake, ["volume", "staging", "--days", "2"]) == 0
    call = fake.calls[0]
    end = dt.datetime.fromisoformat(call[call.index("--end-time") + 1])
    start = dt.datetime.fromisoformat(call[call.index("--start-time") + 1])
    assert end > before
    assert (end.hour, end.minute, end.second) == (0, 0, 0)
    assert end - start == dt.timedelta(days=2)


def test_volume_labels_days_in_utc(monkeypatch, capsys):
    fake = FakeAws(
        {"Datapoints": [{"Timestamp": "2026-11-24T19:00:00-05:00", "Sum": 1024.0}]}
    )
    assert run_main(monkeypatch, fake, ["volume", "staging"]) == 0
    assert capsys.readouterr().out.splitlines() == ["2026-11-25 1.0 KB"]
