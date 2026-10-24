#!/usr/bin/env python3
"""Watch Docker Hub for a new app image tag and open a bump PR when one appears.

Snapshots the current set of tags on Docker Hub, then polls every minute for
10 minutes. If a new tag (one not present in the initial snapshot) appears,
invokes `bump_app_docker_image_version_branch.sh` with that version to create
the branch, commit, push, and open a PR bumping all envs.

If the startup sync check finds a bump already pending (all envs on the same
version but Docker Hub's newest tag is different) and no PR exists yet for
that version's bump branch, the bump runs immediately instead of waiting for
a new tag to appear.

Designed for local operator use. Standard library only.

Assumes the caller is on the `main` branch with a clean working tree; the
bump script branches off whatever HEAD is at when it runs.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

IMAGE_REPO = "automationcalculationsci/automation-calculator"
TAGS_URL = (
    f"https://hub.docker.com/v2/repositories/{IMAGE_REPO}/tags/"
    "?page_size=25&ordering=last_updated"
)
REGISTRY_AUTH_URL = (
    f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{IMAGE_REPO}:pull"
)
REGISTRY_BASE_URL = f"https://registry-1.docker.io/v2/{IMAGE_REPO}"
MANIFEST_ACCEPT = ", ".join([
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
])
REVISION_LABEL = "org.opencontainers.image.revision"
HTTP_TIMEOUT_SECONDS = 15
POLL_INTERVAL_SECONDS = 60
POLL_DURATION_SECONDS = 600
STARTUP_TAGS_TO_DISPLAY = 5
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+-\d+$")
APP_VERSION_RE = re.compile(r'^\s*app_version\s*=\s*"([^"]+)"', re.MULTILINE)
SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
BUMP_SCRIPT = SCRIPTS_DIR / "bump_app_docker_image_version_branch.sh"
TFVARS_ENVS = ("development", "staging", "production")
TFVARS_FILES = {
    env: REPO_ROOT / f"terraform/env/{env}/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
    for env in TFVARS_ENVS
}


def fetch_version_tags() -> list[dict]:
    with urllib.request.urlopen(TAGS_URL, timeout=HTTP_TIMEOUT_SECONDS) as response:
        data = json.load(response)
    return [t for t in data.get("results", []) if VERSION_RE.match(t["name"])]


def fetch_short_commit_hash(tag: str) -> str:
    """Fetch org.opencontainers.image.revision label from the image config.

    Returns "" if the label is absent. The Docker Hub registry requires a bearer
    token even for public repos, but it's anonymous and free.
    """
    with urllib.request.urlopen(REGISTRY_AUTH_URL, timeout=HTTP_TIMEOUT_SECONDS) as response:
        token = json.load(response)["token"]
    headers = {"Authorization": f"Bearer {token}"}

    manifest_req = urllib.request.Request(
        f"{REGISTRY_BASE_URL}/manifests/{tag}",
        headers={**headers, "Accept": MANIFEST_ACCEPT},
    )
    with urllib.request.urlopen(manifest_req, timeout=HTTP_TIMEOUT_SECONDS) as response:
        manifest = json.load(response)
    config_digest = manifest["config"]["digest"]

    blob_req = urllib.request.Request(f"{REGISTRY_BASE_URL}/blobs/{config_digest}", headers=headers)
    with urllib.request.urlopen(blob_req, timeout=HTTP_TIMEOUT_SECONDS) as response:
        config = json.loads(response.read().decode("utf-8"), strict=False)
    labels = config.get("config", {}).get("Labels") or {}
    return labels.get(REVISION_LABEL, "")


def read_tfvars_versions() -> dict[str, str]:
    versions: dict[str, str] = {}
    for env, path in TFVARS_FILES.items():
        match = APP_VERSION_RE.search(path.read_text())
        versions[env] = match.group(1) if match else "<not found>"
    return versions


def find_bump_pr(version: str) -> dict | None:
    """Return {url, state} for a PR (any state) on this version's bump branch, or None."""
    branch = f"bump-app-docker-image-version-{version}"
    result = subprocess.run(
        [
            "gh", "pr", "list",
            "--head", branch,
            "--state", "all",
            "--json", "url,state",
            "--limit", "1",
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "gh pr list failed")
    prs = json.loads(result.stdout or "[]")
    return prs[0] if prs else None


def run_bump(version: str, short_commit_hash: str) -> int:
    print(f"Invoking {BUMP_SCRIPT.name} {version} {short_commit_hash or '<empty>'}")
    result = subprocess.run(
        [str(BUMP_SCRIPT), version, short_commit_hash], cwd=BUMP_SCRIPT.parent
    )
    return result.returncode


def resolve_hash_and_bump(version: str) -> int:
    try:
        short_commit_hash = fetch_short_commit_hash(version)
    except urllib.error.URLError as exc:
        print(f"Failed to fetch revision label: {exc}; bumping with empty hash")
        short_commit_hash = ""
    if not short_commit_hash:
        print(f"Image {version} has no {REVISION_LABEL} label; bumping with empty hash")
    else:
        print(f"Resolved short commit hash: {short_commit_hash}")
    return run_bump(version, short_commit_hash)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--interval",
        type=int,
        default=POLL_INTERVAL_SECONDS,
        help=f"Seconds between polls (default: {POLL_INTERVAL_SECONDS})",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=POLL_DURATION_SECONDS,
        help=f"Total polling window in seconds (default: {POLL_DURATION_SECONDS})",
    )
    args = parser.parse_args()

    print(
        f"Polling {IMAGE_REPO} every {args.interval}s for up to {args.duration}s, "
        f"looking for new version tags matching {VERSION_RE.pattern!r}"
    )

    baseline = fetch_version_tags()
    baseline_names = {t["name"] for t in baseline}
    baseline_sorted = sorted(baseline, key=lambda t: t["last_updated"], reverse=True)

    print()
    if baseline_sorted:
        shown = min(STARTUP_TAGS_TO_DISPLAY, len(baseline_sorted))
        print(f"Docker Hub (newest {shown} of {len(baseline_names)} version tag(s)):")
        for t in baseline_sorted[:shown]:
            print(f"  {t['name']:15s}  {t['last_updated']}")
        hub_newest: str | None = baseline_sorted[0]["name"]
    else:
        print("Docker Hub: no version tags found")
        hub_newest = None

    tfvars_versions = read_tfvars_versions()
    print()
    print("Local tfvars (cluster-addons-layer):")
    for env, version in tfvars_versions.items():
        print(f"  {env:15s}  app_version = {version}")

    deployed = set(tfvars_versions.values())
    pending_version: str | None = None
    print()
    if hub_newest is None:
        print("Sync: cannot compare (no Docker Hub tags)")
    elif deployed == {hub_newest}:
        print(f"Sync: all envs at {hub_newest} (matches Docker Hub newest)")
    elif len(deployed) == 1:
        (current,) = deployed
        print(f"Sync: all envs at {current}, Docker Hub newest is {hub_newest} (bump pending)")
        pending_version = hub_newest
    else:
        print(f"Sync: envs differ ({sorted(deployed)}), Docker Hub newest is {hub_newest}")
    print()

    if pending_version is not None:
        try:
            pr = find_bump_pr(pending_version)
        except (OSError, RuntimeError, json.JSONDecodeError) as exc:
            print(f"Could not check for an existing bump PR: {exc}; watching for new tags instead")
        else:
            if pr is None:
                print(f"No PR found for pending bump to {pending_version}; bumping now")
                return resolve_hash_and_bump(pending_version)
            print(
                f"PR already exists for bump to {pending_version}: "
                f"{pr['url']} ({pr['state']}); watching for new tags"
            )
        print()

    deadline = time.monotonic() + args.duration
    while time.monotonic() < deadline:
        time.sleep(args.interval)
        try:
            current = fetch_version_tags()
        except urllib.error.URLError as exc:
            print(f"Fetch failed: {exc}; retrying next interval")
            continue
        new_tags = [t for t in current if t["name"] not in baseline_names]
        if new_tags:
            target = max(new_tags, key=lambda t: t["last_updated"])
            print(
                f"New tag detected: {target['name']} @ {target['last_updated']} "
                f"({len(new_tags)} new tag(s) total)"
            )
            return resolve_hash_and_bump(target["name"])
        remaining = int(deadline - time.monotonic())
        print(f"No new tags; {remaining}s remaining")

    print("No new tags appeared within polling window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
