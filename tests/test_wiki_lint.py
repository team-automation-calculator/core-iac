"""Tests for scripts/wiki_lint.py."""

import datetime
import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "wiki_lint", REPO_ROOT / "scripts" / "wiki_lint.py"
)
wiki_lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiki_lint)

TODAY = datetime.date(2026, 11, 26)


@pytest.mark.parametrize(
    "text, kind",
    [
        ("account 123456789012 here", "AWS account id"),
        ("zone Z0000000EXAMPLE00000", "Route 53 zone id"),
        ("change C00000000EXAMPLE0000", "Route 53 change id"),
        ("mail someone@example.com", "email address"),
        ("run run-AbCdEfGhIjKlMnOp", "Terraform Cloud run id"),
        ("from 10.0.12.7", "IPv4 address"),
        ("ssoins-0123abcd", "Identity Center instance id"),
        ("store d-0123456789", "identity store id"),
        ("https://x.awsapps.com/start", "Identity Center portal host"),
    ],
)
def test_identifiers_are_found(text, kind):
    assert kind in [found[1] for found in wiki_lint.identifier_findings(text)]


@pytest.mark.parametrize(
    "text",
    [
        "release 1.36.5-20261023 and image 0.9.6-1014",
        "measured 2026-11-25T16:45:34Z, 547 s",
        "provider ~> 6.8 and Terraform 1.17.0",
        "PR #496, merge commit 9e6c36a",
    ],
)
def test_ordinary_text_is_not_an_identifier(text):
    assert wiki_lint.identifier_findings(text) == []


@pytest.mark.parametrize(
    "token, expected",
    [
        ("docs/promotion.md", "docs/promotion.md"),
        ("scripts/env_snapshot.py:12", "scripts/env_snapshot.py"),
        ("terraform/modules/aws/", "terraform/modules/aws"),
        ("AGENTS.md", "AGENTS.md"),
        ("terraform/env/<env>/tf_cloud", None),
        ("values-<env>.yaml", None),
        ("aws_eks_node_group.this[0]", None),
        ("tmp/386/", None),
    ],
)
def test_repo_path_candidate(token, expected):
    assert wiki_lint.repo_path_candidate(token) == expected


def test_missing_references(tmp_path):
    page = tmp_path / "page.md"
    (tmp_path / "other.md").write_text("x")
    text = (
        "[ok](other.md) [gone](gone.md) [web](https://example.com) [anchor](#top)\n"
        "`docs/promotion.md` `docs/no-such-runbook.md`\n"
    )
    assert wiki_lint.missing_references(page, text) == [
        "gone.md",
        "docs/no-such-runbook.md",
    ]


def write_page(directory, name, body):
    page = directory / name
    page.write_text(body)
    return page


def test_lint_page_needs_a_verified_date(tmp_path, caplog):
    page = write_page(tmp_path, "a.md", "# A\n\nNo date.\n")
    assert wiki_lint.lint_page(page, TODAY, 120) == 1
    assert "Verified" in caplog.text


def test_stale_page_warns_without_failing(tmp_path, caplog):
    page = write_page(tmp_path, "a.md", "# A\n\nVerified: 2026-01-01\n")
    assert wiki_lint.lint_page(page, TODAY, 120) == 0
    assert "re-check" in caplog.text


def test_pages_missing_from_index(tmp_path):
    write_page(tmp_path, "index.md", "- [A](a.md)\n")
    write_page(tmp_path, "a.md", "")
    write_page(tmp_path, "b.md", "")
    assert wiki_lint.pages_missing_from_index(tmp_path) == ["b.md"]


def test_the_repo_wiki_passes():
    assert wiki_lint.main([]) == 0
