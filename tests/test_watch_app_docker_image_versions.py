from __future__ import annotations

import sys

import pytest

import app_image_provenance as prov
import watch_app_docker_image_versions as watch
from conftest import BRANCH_SHA, ON_MAIN_SHA, add_image, add_revision

OTHER_MAIN_SHA = "1111111111111111111111111111111111111111"


def tag(name: str, minute: int) -> dict:
    return {"name": name, "last_updated": f"2026-10-23T00:{minute:02d}:00Z"}


class Harness:
    """Drives watch.main() with a fake clock, Docker Hub tag list and provenance."""

    def __init__(self, monkeypatch, polls: list[list[dict]], baseline: list[dict]):
        self.clock = 0.0
        self.tag_lists = [baseline, *polls]
        self.provenance: dict[str, prov.Provenance | Exception] = {}
        self.provenance_calls: list[str] = []
        self.bumps: list[tuple[str, str]] = []
        self.pr: dict | None = None
        self.tfvars = {env: "0.9.6-871" for env in watch.TFVARS_ENVS}

        monkeypatch.setattr(watch.time, "sleep", self._sleep)
        monkeypatch.setattr(watch.time, "monotonic", lambda: self.clock)
        monkeypatch.setattr(watch, "fetch_version_tags", self._fetch_tags)
        monkeypatch.setattr(watch, "read_tfvars_versions", lambda: dict(self.tfvars))
        monkeypatch.setattr(watch, "find_bump_pr", lambda version: self.pr)
        monkeypatch.setattr(watch, "check_provenance", self._check_provenance)
        monkeypatch.setattr(watch, "run_bump", self._run_bump)
        monkeypatch.setattr(
            sys, "argv", ["watch", "--interval", "60", "--duration", "180"]
        )

    def _sleep(self, seconds: float) -> None:
        self.clock += seconds

    def _fetch_tags(self) -> list[dict]:
        if len(self.tag_lists) > 1:
            return self.tag_lists.pop(0)
        return self.tag_lists[0]

    def _check_provenance(self, version: str) -> prov.Provenance:
        self.provenance_calls.append(version)
        result = self.provenance[version]
        if isinstance(result, Exception):
            raise result
        return result

    def _run_bump(self, version: str, commit_hash: str) -> int:
        self.bumps.append((version, commit_hash))
        return 0

    def on_main(self, version: str, sha: str = ON_MAIN_SHA) -> None:
        self.provenance[version] = prov.Provenance(version, sha, "identical")

    def off_main(self, version: str, sha: str = BRANCH_SHA) -> None:
        self.provenance[version] = prov.Provenance(version, sha, "ahead")


BASELINE = [tag("0.9.6-871", 1)]


def test_off_main_new_tag_is_skipped_and_later_main_tag_is_bumped(monkeypatch, capsys):
    polls = [
        [*BASELINE, tag("0.9.6-872", 2)],
        [*BASELINE, tag("0.9.6-872", 2), tag("0.9.6-873", 3)],
    ]
    h = Harness(monkeypatch, polls, BASELINE)
    h.off_main("0.9.6-872")
    h.on_main("0.9.6-873", OTHER_MAIN_SHA)

    assert watch.main() == 0

    assert h.bumps == [("0.9.6-873", OTHER_MAIN_SHA)]
    # The skipped tag joins the baseline and is not re-checked on later polls.
    assert h.provenance_calls == ["0.9.6-872", "0.9.6-873"]
    assert "Skipping 0.9.6-872" in capsys.readouterr().out


def test_unverifiable_new_tag_is_skipped_and_watch_continues(monkeypatch, capsys):
    polls = [[*BASELINE, tag("0.9.6-872", 2)]]
    h = Harness(monkeypatch, polls, BASELINE)
    h.provenance["0.9.6-872"] = prov.ProvenanceError("no label")

    assert watch.main() == 0

    assert h.bumps == []
    assert h.provenance_calls == ["0.9.6-872"]
    out = capsys.readouterr().out
    assert "provenance unverified (no label)" in out
    assert "No new tags built from app main appeared within polling window" in out


def test_newest_on_main_tag_is_bumped(monkeypatch):
    polls = [[*BASELINE, tag("0.9.6-872", 2)]]
    h = Harness(monkeypatch, polls, BASELINE)
    h.on_main("0.9.6-872")

    assert watch.main() == 0
    assert h.bumps == [("0.9.6-872", ON_MAIN_SHA)]


def test_no_new_tags_exits_cleanly(monkeypatch, capsys):
    h = Harness(monkeypatch, [], BASELINE)

    assert watch.main() == 0
    assert h.bumps == []
    assert h.provenance_calls == []
    assert "No new tags; " in capsys.readouterr().out


def test_pending_off_main_bump_is_skipped_and_watch_continues(monkeypatch, capsys):
    baseline = [*BASELINE, tag("0.9.6-874", 4)]
    h = Harness(monkeypatch, [], baseline)
    h.off_main("0.9.6-874")

    assert watch.main() == 0

    assert h.bumps == []
    out = capsys.readouterr().out
    assert "bump pending" in out
    assert "Skipping 0.9.6-874" in out
    assert "Watching for new tags instead" in out


def test_pending_on_main_bump_runs_immediately(monkeypatch):
    baseline = [*BASELINE, tag("0.9.6-872", 2)]
    h = Harness(monkeypatch, [], baseline)
    h.on_main("0.9.6-872")

    assert watch.main() == 0
    assert h.bumps == [("0.9.6-872", ON_MAIN_SHA)]
    assert h.clock == 0  # bumped before polling


def test_pending_bump_with_existing_pr_watches(monkeypatch, capsys):
    baseline = [*BASELINE, tag("0.9.6-872", 2)]
    h = Harness(monkeypatch, [], baseline)
    h.pr = {"url": "https://github.com/x/y/pull/1", "state": "OPEN"}

    assert watch.main() == 0
    assert h.bumps == []
    assert h.provenance_calls == []
    assert "PR already exists" in capsys.readouterr().out


@pytest.mark.parametrize(
    "sha, status, expected",
    [(ON_MAIN_SHA, "behind", ON_MAIN_SHA), (BRANCH_SHA, "diverged", None)],
)
def test_resolve_main_commit_hash(fake_http, sha, status, expected):
    add_revision(fake_http, "0.9.6-9", sha, status)
    assert watch.resolve_main_commit_hash("0.9.6-9") == expected


def test_resolve_main_commit_hash_missing_label_skips(fake_http):
    add_image(fake_http, "0.9.6-9", None)
    assert watch.resolve_main_commit_hash("0.9.6-9") is None
