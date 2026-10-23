from __future__ import annotations

import pytest

import app_image_provenance as prov
from conftest import (
    BRANCH_SHA,
    ON_MAIN_SHA,
    add_image,
    add_revision,
    compare_url,
    http_error,
    manifest_url,
)


@pytest.mark.parametrize("status", ["behind", "identical"])
def test_ancestor_of_main_is_on_main(fake_http, status):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, status)

    result = prov.check_provenance("0.9.6-871")

    assert result == prov.Provenance("0.9.6-871", ON_MAIN_SHA, status)
    assert result.on_main


@pytest.mark.parametrize("status", ["ahead", "diverged"])
def test_branch_only_commit_is_not_on_main(fake_http, status):
    add_revision(fake_http, "0.9.6-872", BRANCH_SHA, status)

    result = prov.check_provenance("0.9.6-872")

    assert result.sha == BRANCH_SHA
    assert result.status == status
    assert not result.on_main


def test_compare_uses_full_sha_against_app_main(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")

    prov.check_provenance("0.9.6-871")

    assert compare_url(ON_MAIN_SHA) in fake_http.urls()


@pytest.mark.parametrize("labels", [None, {}, {prov.REVISION_LABEL: ""}])
def test_missing_label_raises(fake_http, labels):
    add_image(fake_http, "0.9.6-1", labels)

    with pytest.raises(prov.ProvenanceError, match="has no .* label"):
        prov.check_provenance("0.9.6-1")


def test_non_sha_label_raises(fake_http):
    add_image(fake_http, "0.9.6-1", {prov.REVISION_LABEL: "main; rm -rf /"})

    with pytest.raises(prov.ProvenanceError, match="not a git sha"):
        prov.check_provenance("0.9.6-1")


def test_registry_error_raises(fake_http):
    add_image(fake_http, "0.9.6-1", {prov.REVISION_LABEL: ON_MAIN_SHA})
    fake_http.add(manifest_url("0.9.6-1"), http_error(manifest_url("0.9.6-1"), 404))

    with pytest.raises(prov.ProvenanceError, match="HTTP 404"):
        prov.check_provenance("0.9.6-1")


def test_github_api_error_raises(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")
    fake_http.add(compare_url(ON_MAIN_SHA), http_error(compare_url(ON_MAIN_SHA), 500))

    with pytest.raises(prov.ProvenanceError, match="compare main.*HTTP 500"):
        prov.check_provenance("0.9.6-871")


def test_github_rate_limit_message_suggests_token(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")
    fake_http.add(
        compare_url(ON_MAIN_SHA),
        http_error(compare_url(ON_MAIN_SHA), 403, {"X-RateLimit-Remaining": "0"}),
    )

    with pytest.raises(prov.ProvenanceError, match="rate limit.*GITHUB_TOKEN"):
        prov.check_provenance("0.9.6-871")


def test_github_timeout_raises(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")
    fake_http.add(compare_url(ON_MAIN_SHA), TimeoutError("timed out"))

    with pytest.raises(prov.ProvenanceError, match="TimeoutError"):
        prov.check_provenance("0.9.6-871")


def test_github_malformed_body_raises(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")
    fake_http.add(compare_url(ON_MAIN_SHA), b"<html>not json</html>")

    with pytest.raises(prov.ProvenanceError, match="compare main"):
        prov.check_provenance("0.9.6-871")


def test_unexpected_compare_status_raises(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "")

    with pytest.raises(prov.ProvenanceError, match="unexpected status"):
        prov.check_provenance("0.9.6-871")


def test_short_sha_is_resolved_via_commits_api(fake_http):
    add_image(fake_http, "0.9.6-871", {prov.REVISION_LABEL: ON_MAIN_SHA[:7]})
    fake_http.add(
        f"{prov.GITHUB_API_URL}/repos/{prov.APP_GITHUB_REPO}/commits/{ON_MAIN_SHA[:7]}",
        {"sha": ON_MAIN_SHA},
    )
    fake_http.add(compare_url(ON_MAIN_SHA), {"status": "behind"})

    result = prov.check_provenance("0.9.6-871")

    assert result.sha == ON_MAIN_SHA
    assert result.on_main


def test_github_token_is_sent_when_set(fake_http, monkeypatch):
    monkeypatch.setenv("GH_TOKEN", "secret")
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")

    prov.check_provenance("0.9.6-871")

    github_request = fake_http.requests[-1]
    assert github_request.get_header("Authorization") == "Bearer secret"


def test_github_unauthenticated_when_no_token(fake_http):
    add_revision(fake_http, "0.9.6-871", ON_MAIN_SHA, "identical")

    prov.check_provenance("0.9.6-871")

    assert fake_http.requests[-1].get_header("Authorization") is None
