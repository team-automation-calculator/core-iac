#!/usr/bin/env python3
"""Check that an app Docker image was built from automation-calculator `main`.

Reads the image's `org.opencontainers.image.revision` label from the Docker Hub
registry (anonymous bearer token), then asks the GitHub compare API whether
that commit is an ancestor of the app repo's `main`:

    GET /repos/{owner}/{repo}/compare/main...{sha}

`behind` or `identical` means the commit is on main; `ahead` or `diverged`
means it is not (e.g. an image built from an unmerged branch).

Shared by `check_app_docker_image_versions.py` (CI, fails closed) and
`watch_app_docker_image_versions.py` (local, skips off-main tags). Can also be
run directly, read-only, to check tags by hand:

    scripts/app_image_provenance.py 0.9.6-871 0.9.6-872

Uses GITHUB_TOKEN or GH_TOKEN for the GitHub API if set, otherwise calls it
unauthenticated (the app repo is public; the anonymous limit is 60 req/hour).
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass

IMAGE_REPO = "automationcalculationsci/automation-calculator"
APP_GITHUB_REPO = "team-automation-calculator/automation-calculator"
APP_MAIN_BRANCH = "main"
REGISTRY_AUTH_URL = (
    "https://auth.docker.io/token?service=registry.docker.io"
    f"&scope=repository:{IMAGE_REPO}:pull"
)
REGISTRY_BASE_URL = f"https://registry-1.docker.io/v2/{IMAGE_REPO}"
MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
    ]
)
REVISION_LABEL = "org.opencontainers.image.revision"
GITHUB_API_URL = "https://api.github.com"
HTTP_TIMEOUT_SECONDS = 15
ON_MAIN_STATUSES = frozenset({"behind", "identical"})
OFF_MAIN_STATUSES = frozenset({"ahead", "diverged"})
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
FULL_SHA_LENGTH = 40


class ProvenanceError(Exception):
    """The image's provenance could not be determined (treat as not verified)."""


@dataclass(frozen=True)
class Provenance:
    tag: str
    sha: str
    status: str

    @property
    def on_main(self) -> bool:
        return self.status in ON_MAIN_STATUSES


def _get_json(request: urllib.request.Request | str) -> dict:
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"), strict=False)


def fetch_revision_label(tag: str) -> str:
    """Return the image's revision label, or "" if the label is absent.

    The Docker Hub registry requires a bearer token even for public repos, but
    it's anonymous and free. Raises urllib.error.URLError on HTTP failures.
    """
    token = _get_json(REGISTRY_AUTH_URL)["token"]
    headers = {"Authorization": f"Bearer {token}"}

    manifest = _get_json(
        urllib.request.Request(
            f"{REGISTRY_BASE_URL}/manifests/{tag}",
            headers={**headers, "Accept": MANIFEST_ACCEPT},
        )
    )
    config_digest = manifest["config"]["digest"]

    config = _get_json(
        urllib.request.Request(
            f"{REGISTRY_BASE_URL}/blobs/{config_digest}", headers=headers
        )
    )
    labels = config.get("config", {}).get("Labels") or {}
    return labels.get(REVISION_LABEL, "")


def _github_request(path: str) -> urllib.request.Request:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "core-iac-app-image-provenance",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(f"{GITHUB_API_URL}{path}", headers=headers)


# Network failures (URLError, HTTPError, timeouts) are all OSError; malformed
# bodies raise ValueError (JSONDecodeError) or KeyError.
FETCH_ERRORS = (OSError, ValueError, KeyError)


def _describe_error(exc: Exception) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        detail = f"HTTP {exc.code}"
        if exc.code in (403, 429) and exc.headers.get("X-RateLimit-Remaining") == "0":
            detail += " (GitHub API rate limit exhausted; set GITHUB_TOKEN)"
        return detail
    if isinstance(exc, urllib.error.URLError):
        return str(exc.reason)
    return f"{type(exc).__name__}: {exc}"


def resolve_full_sha(sha: str) -> str:
    """Expand a short sha to the full 40-char sha via the GitHub commits API."""
    if len(sha) == FULL_SHA_LENGTH:
        return sha
    try:
        commit = _get_json(_github_request(f"/repos/{APP_GITHUB_REPO}/commits/{sha}"))
        return commit["sha"]
    except FETCH_ERRORS as exc:
        raise ProvenanceError(
            f"could not resolve short sha {sha} in {APP_GITHUB_REPO}: "
            f"{_describe_error(exc)}"
        ) from exc


def compare_with_main(sha: str) -> str:
    """Return the GitHub compare status of main...sha (behind/identical/ahead/diverged)."""
    path = f"/repos/{APP_GITHUB_REPO}/compare/{APP_MAIN_BRANCH}...{sha}"
    try:
        status = _get_json(_github_request(path)).get("status", "")
    except (*FETCH_ERRORS, AttributeError) as exc:
        raise ProvenanceError(
            f"GitHub compare {APP_MAIN_BRANCH}...{sha} failed: {_describe_error(exc)}"
        ) from exc
    if status not in ON_MAIN_STATUSES | OFF_MAIN_STATUSES:
        raise ProvenanceError(
            f"GitHub compare {APP_MAIN_BRANCH}...{sha} returned unexpected status "
            f"{status!r}"
        )
    return status


def check_provenance(tag: str) -> Provenance:
    """Return the tag's revision and its relation to app main.

    Raises ProvenanceError if the label is missing or malformed, or if any
    registry/GitHub call fails, so callers can fail closed.
    """
    try:
        label = fetch_revision_label(tag)
    except (*FETCH_ERRORS, AttributeError, TypeError) as exc:
        raise ProvenanceError(
            f"could not read {REVISION_LABEL} for {IMAGE_REPO}:{tag}: "
            f"{_describe_error(exc)}"
        ) from exc
    if not isinstance(label, str):
        raise ProvenanceError(
            f"{IMAGE_REPO}:{tag} {REVISION_LABEL} is not a string: {label!r}"
        )
    label = label.strip().lower()
    if not label:
        raise ProvenanceError(f"{IMAGE_REPO}:{tag} has no {REVISION_LABEL} label")
    if not SHA_RE.match(label):
        raise ProvenanceError(
            f"{IMAGE_REPO}:{tag} {REVISION_LABEL} is not a git sha: {label!r}"
        )
    sha = resolve_full_sha(label)
    return Provenance(tag=tag, sha=sha, status=compare_with_main(sha))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("tags", nargs="+", help="Image tags, e.g. 0.9.6-871")
    args = parser.parse_args()

    failed = False
    for tag in args.tags:
        try:
            result = check_provenance(tag)
        except ProvenanceError as exc:
            print(f"UNVERIFIED: {IMAGE_REPO}:{tag} ({exc})")
            failed = True
            continue
        if result.on_main:
            print(
                f"ON MAIN: {IMAGE_REPO}:{tag} rev {result.sha} "
                f"(compare {APP_MAIN_BRANCH}...{result.sha}: {result.status})"
            )
        else:
            print(
                f"NOT ON MAIN: {IMAGE_REPO}:{tag} rev {result.sha} "
                f"(compare {APP_MAIN_BRANCH}...{result.sha}: {result.status})"
            )
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
