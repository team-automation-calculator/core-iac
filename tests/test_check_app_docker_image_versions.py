from __future__ import annotations

import sys

import pytest

import check_app_docker_image_versions as check
from conftest import BRANCH_SHA, ON_MAIN_SHA, add_image, add_revision, http_error

DIFF = """\
--- a/terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars
+++ b/terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars
-app_version                    = "0.9.6-870"
+app_version                    = "{version}"
"""


def hub_url(tag: str) -> str:
    return check.DOCKER_HUB_TAG_URL.format(repo=check.IMAGE_REPO, tag=tag)


@pytest.fixture
def run_check(monkeypatch):
    def run(*versions: str) -> int:
        diff = "".join(DIFF.format(version=v) for v in versions)
        monkeypatch.setattr(check, "git_diff", lambda base: diff)
        monkeypatch.setattr(sys, "argv", ["check_app_docker_image_versions.py"])
        return check.main()

    return run


def test_added_versions_parses_plus_lines():
    diff = DIFF.format(version="0.9.6-871") + DIFF.format(version="0.9.6-871")
    assert check.added_versions(diff) == ["0.9.6-871"]


def test_no_changes_skips(run_check, capsys):
    assert run_check() == 0
    assert "No app_version changes detected" in capsys.readouterr().out


def test_on_main_version_passes(fake_http, run_check, capsys):
    fake_http.add(hub_url("0.9.6-871"), {})
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")

    assert run_check("0.9.6-871") == 0
    out = capsys.readouterr().out
    assert f"OK: {check.IMAGE_REPO}:0.9.6-871 rev {ON_MAIN_SHA}" in out
    assert "identical" in out


def test_branch_only_version_fails(fake_http, run_check, capsys):
    fake_http.add(hub_url("0.9.6-872"), {})
    add_revision(fake_http, "0.9.6-872", BRANCH_SHA, "ahead")

    assert run_check("0.9.6-872") == 1
    out = capsys.readouterr().out
    assert f"NOT ON MAIN: {check.IMAGE_REPO}:0.9.6-872 rev {BRANCH_SHA}" in out
    assert f"main...{BRANCH_SHA}: ahead" in out


def test_missing_label_fails_closed(fake_http, run_check, capsys):
    fake_http.add(hub_url("0.9.6-1"), {})
    add_image(fake_http, "0.9.6-1", {})

    assert run_check("0.9.6-1") == 1
    out = capsys.readouterr().out
    assert "UNVERIFIED" in out
    assert "failing closed" in out


def test_github_api_error_fails_closed(fake_http, run_check, capsys):
    fake_http.add(hub_url("0.9.6-871"), {})
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")
    fake_http.add(
        f"https://api.github.com/repos/team-automation-calculator/"
        f"automation-calculator/compare/main...{ON_MAIN_SHA}",
        http_error("https://api.github.com", 502),
    )

    assert run_check("0.9.6-871") == 1
    assert "UNVERIFIED" in capsys.readouterr().out


def test_missing_tag_fails_without_provenance_lookup(fake_http, run_check, capsys):
    fake_http.add(hub_url("0.9.6-999"), http_error(hub_url("0.9.6-999"), 404))

    assert run_check("0.9.6-999") == 1
    assert (
        f"MISSING: {check.IMAGE_REPO}:0.9.6-999 (HTTP 404)" in capsys.readouterr().out
    )
    assert fake_http.urls() == [hub_url("0.9.6-999")]


def test_any_failure_fails_the_run(fake_http, run_check, capsys):
    for tag, sha, status in [
        ("0.9.6-871", ON_MAIN_SHA, "identical"),
        ("0.9.6-872", BRANCH_SHA, "ahead"),
    ]:
        fake_http.add(hub_url(tag), {})
        add_revision(fake_http, tag, sha, status)

    assert run_check("0.9.6-871", "0.9.6-872") == 1
    out = capsys.readouterr().out
    assert "OK:" in out
    assert "NOT ON MAIN:" in out
