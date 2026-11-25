"""Tests for describe, probe, Tally and main in scripts/health_poll.py."""

import io
import sys
import urllib.error

import health_poll
import pytest
from health_poll import Tally, describe, probe

# describe


def test_describe_reads_hash_and_database():
    body = '{"current_time_in_unix":1795625123,"short_commit_hash":"a8af890","database":"ok"}'
    assert describe(body) == "a8af890 database=ok"


@pytest.mark.parametrize("body", ["<html>502</html>", "", "[1, 2]"])
def test_describe_unparseable(body):
    assert describe(body) == "unparseable"


def test_describe_missing_keys():
    assert describe("{}") == "- database=-"


# probe


class FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_probe_ok(monkeypatch):
    body = b'{"short_commit_hash":"a8af890","database":"ok"}'
    monkeypatch.setattr(
        health_poll.urllib.request, "urlopen", lambda *a, **k: FakeResponse(body)
    )
    assert probe("https://example.invalid/health", 1) == "200 a8af890 database=ok"


def test_probe_http_error(monkeypatch):
    def raise_503(*args, **kwargs):
        raise urllib.error.HTTPError(
            "https://example.invalid/health", 503, "down", {}, None
        )

    monkeypatch.setattr(health_poll.urllib.request, "urlopen", raise_503)
    assert probe("https://example.invalid/health", 1) == "503 -"


def test_probe_connection_error(monkeypatch):
    def refuse(*args, **kwargs):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(health_poll.urllib.request, "urlopen", refuse)
    assert probe("https://example.invalid/health", 1) == "error connection refused"


# Tally


def test_tally_all_ok():
    tally = Tally()
    for now in (0, 5, 10):
        tally.add("200 a8af890 database=ok", now)
    assert (
        tally.summary(15)
        == "summary polls=3 ok=3 not_ok=0 longest_not_ok=0s hashes=a8af890"
    )


def test_tally_outage_is_measured_to_the_next_ok():
    tally = Tally()
    tally.add("200 aaa1111 database=ok", 0)
    tally.add("503 -", 5)
    tally.add("error timed out", 10)
    tally.add("200 bbb2222 database=ok", 15)
    tally.add("503 -", 20)
    tally.add("200 bbb2222 database=ok", 25)
    assert (
        tally.summary(30)
        == "summary polls=6 ok=3 not_ok=3 longest_not_ok=10s hashes=aaa1111,bbb2222"
    )


def test_tally_outage_still_open_at_the_end():
    tally = Tally()
    tally.add("200 aaa1111 database=ok", 0)
    tally.add("503 -", 5)
    assert (
        tally.summary(65)
        == "summary polls=2 ok=1 not_ok=1 longest_not_ok=60s hashes=aaa1111"
    )


# main


def run_main(monkeypatch, tmp_path, results, extra_args=()):
    remaining = iter(results)
    monkeypatch.setattr(health_poll, "probe", lambda url, timeout: next(remaining))
    monkeypatch.setattr(health_poll.time, "sleep", lambda seconds: None)
    clock = iter(range(0, 10_000, 5))
    monkeypatch.setattr(health_poll.time, "monotonic", lambda: next(clock))
    log = tmp_path / "health.log"
    monkeypatch.setattr(
        sys,
        "argv",
        ["health_poll.py", "staging", str(log), "--minutes", "0.5", *extra_args],
    )
    code = health_poll.main()
    return code, [line.split(" ", 1)[1] for line in log.read_text().splitlines()]


def test_main_logs_changes_only_and_exits_zero(monkeypatch, tmp_path):
    code, lines = run_main(monkeypatch, tmp_path, ["200 aaa1111 database=ok"] * 10)
    assert code == 0
    assert lines[0] == "200 aaa1111 database=ok"
    assert lines[-1].startswith("summary polls=")
    assert len(lines) == 2


def test_main_exits_one_after_a_failed_poll(monkeypatch, tmp_path):
    results = ["200 aaa1111 database=ok", "503 -"] + ["200 aaa1111 database=ok"] * 10
    code, lines = run_main(monkeypatch, tmp_path, results)
    assert code == 1
    assert lines[:3] == ["200 aaa1111 database=ok", "503 -", "200 aaa1111 database=ok"]


def test_main_until_hash_stops_at_the_flip(monkeypatch, tmp_path):
    results = [
        "200 aaa1111 database=ok",
        "200 bbb2222 database=ok",
        "200 ccc3333 database=ok",
    ]
    code, lines = run_main(monkeypatch, tmp_path, results, ["--until-hash", "bbb2222"])
    assert code == 0
    assert (
        lines[-1]
        == "summary polls=2 ok=2 not_ok=0 longest_not_ok=0s hashes=aaa1111,bbb2222"
    )


def test_main_until_hash_never_seen(monkeypatch, tmp_path):
    code, _ = run_main(
        monkeypatch,
        tmp_path,
        ["200 aaa1111 database=ok"] * 10,
        ["--until-hash", "bbb2222"],
    )
    assert code == 2
