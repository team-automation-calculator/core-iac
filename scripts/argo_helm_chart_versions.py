#!/usr/bin/env python3
"""Print the latest stable chart versions from the argo-helm repository index.

Reads a downloaded copy of https://argoproj.github.io/argo-helm/index.yaml
(use --fetch to download it into tmp/argo-helm-index/ first) and prints, for
each requested chart, the highest non-prerelease, non-deprecated version and
its appVersion. The index is parsed line by line on the standard library only,
so no PyYAML or yq is needed. Run it with `python3 -I` because the index is
downloaded content.

Used by Phase 0 of docs/argocd-migration-plan.md to pin the argo-cd and
argocd-apps chart versions.

    python3 -I scripts/argo_helm_chart_versions.py --fetch
    python3 -I scripts/argo_helm_chart_versions.py --index tmp/argo-helm-index/index.yaml
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path
from typing import Optional

INDEX_URL = "https://argoproj.github.io/argo-helm/index.yaml"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INDEX_PATH = REPO_ROOT / "tmp" / "argo-helm-index" / "index.yaml"
DEFAULT_CHARTS = ("argo-cd", "argocd-apps")
HTTP_TIMEOUT_SECONDS = 60

CHART_HEADER_RE = re.compile(r"^  ([A-Za-z0-9_.-]+):\s*$")
# An entry's first line is "  - <key>: <value>" or "  - <key>:" (a nested map
# such as annotations); later scalar fields sit at four spaces.
ITEM_START_RE = re.compile(r"^  - (\w+):(?: (.*))?$")
ITEM_FIELD_RE = re.compile(r"^    (\w+):(?: (.*))?$")
SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_index(text: str) -> dict[str, list[dict[str, str]]]:
    """Return {chart name: [entry fields, ...]} from an index.yaml body.

    Only top-level scalar fields of each entry are kept; nested maps and lists
    (dependencies, maintainers, urls) are ignored.
    """
    entries: dict[str, list[dict[str, str]]] = {}
    chart: Optional[str] = None
    current: Optional[dict[str, str]] = None
    in_entries = False

    for line in text.splitlines():
        if not in_entries:
            in_entries = line.startswith("entries:")
            continue
        if line and not line.startswith(" "):
            break  # left the entries block (generated:, etc.)

        header = CHART_HEADER_RE.match(line)
        if header:
            chart = header.group(1)
            entries.setdefault(chart, [])
            current = None
            continue
        if chart is None:
            continue

        item = ITEM_START_RE.match(line)
        if item:
            current = {item.group(1): unquote(item.group(2) or "")}
            entries[chart].append(current)
            continue

        field = ITEM_FIELD_RE.match(line)
        if field and current is not None:
            current[field.group(1)] = unquote(field.group(2) or "")

    return entries


def semver_key(version: str) -> Optional[tuple[int, int, int]]:
    match = SEMVER_RE.match(version)
    if not match or match.group(4):  # unparseable or prerelease
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def latest_stable(items: list[dict[str, str]]) -> Optional[dict[str, str]]:
    best: Optional[dict[str, str]] = None
    best_key: Optional[tuple[int, int, int]] = None
    for item in items:
        if item.get("deprecated", "false").lower() == "true":
            continue
        key = semver_key(item.get("version", ""))
        if key is None:
            continue
        if best_key is None or key > best_key:
            best, best_key = item, key
    return best


def fetch_index(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(INDEX_URL, timeout=HTTP_TIMEOUT_SECONDS) as response:
        path.write_bytes(response.read())


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--index",
        type=Path,
        default=DEFAULT_INDEX_PATH,
        help="Path to a downloaded index.yaml (default: tmp/argo-helm-index/index.yaml)",
    )
    parser.add_argument(
        "--fetch",
        action="store_true",
        help=f"Download {INDEX_URL} to --index before reading it",
    )
    parser.add_argument(
        "charts",
        nargs="*",
        default=list(DEFAULT_CHARTS),
        help=f"Chart names to report (default: {' '.join(DEFAULT_CHARTS)})",
    )
    args = parser.parse_args()

    if args.fetch:
        fetch_index(args.index)
    if not args.index.is_file():
        print(f"Index not found: {args.index} (run with --fetch)", file=sys.stderr)
        return 2

    entries = parse_index(args.index.read_text(encoding="utf-8"))

    missing = False
    for chart in args.charts:
        latest = latest_stable(entries.get(chart, []))
        if latest is None:
            print(f"{chart}: no stable version found in index", file=sys.stderr)
            missing = True
            continue
        app_version = latest.get("appVersion") or "-"
        created = (latest.get("created") or "")[:10]
        print(f"{chart} {latest['version']} appVersion={app_version} created={created}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
