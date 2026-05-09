#!/usr/bin/env python3
"""Check that any app_version values added in this branch exist on Docker Hub.

Diffs `<base>..HEAD` over the cluster-addons-layer terraform.tfvars files,
extracts versions added on `+app_version` lines, and checks each tag against
the Docker Hub registry API. Exits non-zero if any tag is missing.

Designed for CircleCI; runs on the standard library only.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import urllib.error
import urllib.request

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

    failed = False
    for version in versions:
        status = tag_status(IMAGE_REPO, version)
        if status == 200:
            print(f"OK: {IMAGE_REPO}:{version}")
        else:
            print(f"MISSING: {IMAGE_REPO}:{version} (HTTP {status})")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
