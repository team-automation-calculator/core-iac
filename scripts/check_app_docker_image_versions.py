#!/usr/bin/env python3
"""Check that app_version values added in this branch are deployable.

Diffs `<base>..HEAD` over the cluster-addons-layer terraform.tfvars files,
extracts versions added on `+app_version` lines, and for each tag checks:

1. it exists on Docker Hub, and
2. its `org.opencontainers.image.revision` commit is on automation-calculator
   `main` (see app_image_provenance.py), so images built from unmerged app
   branches can't be deployed.

Fails closed: a missing tag, a missing revision label, an off-main revision,
or any registry/GitHub API error exits non-zero.

Designed for CircleCI; runs on the standard library only. Set GITHUB_TOKEN or
GH_TOKEN to avoid the anonymous GitHub API rate limit.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import urllib.error
import urllib.request

from app_image_provenance import (
    APP_MAIN_BRANCH,
    ProvenanceError,
    check_provenance,
)

TFVARS_PATHSPEC = "terraform/env/*/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
VAR_NAME = "app_version"
IMAGE_REPO = "automationcalculationsci/automation-calculator"
DOCKER_HUB_TAG_URL = "https://hub.docker.com/v2/repositories/{repo}/tags/{tag}/"
HTTP_TIMEOUT_SECONDS = 15

ADDED_VERSION_RE = re.compile(rf'^\+\s*{re.escape(VAR_NAME)}\s*=\s*"([^"]+)"')


def git_diff(base: str) -> str:
    result = subprocess.run(
        ["git", "diff", f"{base}..HEAD", "--", TFVARS_PATHSPEC],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def added_versions(diff_text: str) -> list[str]:
    versions: set[str] = set()
    for line in diff_text.splitlines():
        match = ADDED_VERSION_RE.match(line)
        if match:
            versions.add(match.group(1))
    return sorted(versions)


def tag_status(repo: str, tag: str) -> int:
    url = DOCKER_HUB_TAG_URL.format(repo=repo, tag=tag)
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def check_version(version: str) -> bool:
    """Print the result for one tag; return True if it is deployable."""
    image = f"{IMAGE_REPO}:{version}"
    try:
        status = tag_status(IMAGE_REPO, version)
    except OSError as exc:
        print(f"MISSING: {image} (Docker Hub lookup failed: {exc})")
        return False
    if status != 200:
        print(f"MISSING: {image} (HTTP {status})")
        return False

    try:
        provenance = check_provenance(version)
    except ProvenanceError as exc:
        print(f"UNVERIFIED: {image} ({exc}); failing closed")
        return False
    compare = f"compare {APP_MAIN_BRANCH}...{provenance.sha}: {provenance.status}"
    if not provenance.on_main:
        print(
            f"NOT ON MAIN: {image} rev {provenance.sha} ({compare}); "
            f"image was not built from automation-calculator {APP_MAIN_BRANCH}"
        )
        return False
    print(f"OK: {image} rev {provenance.sha} ({compare})")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base",
        default="origin/main",
        help="Git ref to diff against (default: origin/main)",
    )
    args = parser.parse_args()

    diff = git_diff(args.base)
    versions = added_versions(diff)
    if not versions:
        print(f"No {VAR_NAME} changes detected, skipping Docker Hub validation")
        return 0

    results = [check_version(version) for version in versions]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
