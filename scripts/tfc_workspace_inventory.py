#!/usr/bin/env python3
"""Inventory the Terraform Cloud organization for the Spacelift migration plan.

Prints one Markdown table row per workspace: name, resources under management,
Terraform version, auto-apply, working directory, trigger prefixes, inbound run
triggers, remote-state consumers and variable names (values are never printed).
The resource counts feed the cost comparison in
plans/tfc-to-spacelift-migration.md.

Usage:
    TFE_TOKEN=... python3 scripts/tfc_workspace_inventory.py [--org team-automation-calculator]

Read-only: every request is a GET.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://app.terraform.io/api/v2"


def get(path: str, token: str) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/vnd.api+json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def paged(path: str, token: str) -> list[dict]:
    items: list[dict] = []
    page = 1
    while True:
        sep = "&" if "?" in path else "?"
        body = get(f"{path}{sep}page%5Bsize%5D=100&page%5Bnumber%5D={page}", token)
        items.extend(body.get("data", []))
        if not body.get("meta", {}).get("pagination", {}).get("next-page"):
            return items
        page += 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inventory the Terraform Cloud organization for the Spacelift migration plan."
    )
    parser.add_argument("--org", default="team-automation-calculator")
    args = parser.parse_args()

    token = os.environ.get("TFE_TOKEN")
    if not token:
        print("TFE_TOKEN is not set", file=sys.stderr)
        return 2

    org = urllib.parse.quote(args.org)
    workspaces = paged(f"/organizations/{org}/workspaces", token)
    by_id = {w["id"]: w["attributes"]["name"] for w in workspaces}

    print(
        "| Workspace | Resources | TF version | Auto-apply | Working directory "
        "| Trigger prefixes | Triggered by | State consumers | Variables |"
    )
    print("|---|---|---|---|---|---|---|---|---|")
    total = 0
    for w in sorted(workspaces, key=lambda x: x["attributes"]["name"]):
        a = w["attributes"]
        wid = w["id"]
        total += a.get("resource-count") or 0

        triggers = paged(
            f"/workspaces/{wid}/run-triggers?filter%5Brun-trigger%5D%5Btype%5D=inbound",
            token,
        )
        triggered_by = ", ".join(
            by_id.get(t["relationships"]["sourceable"]["data"]["id"], "?")
            for t in triggers
        )
        consumers = paged(f"/workspaces/{wid}/relationships/remote-state-consumers", token)
        consumer_names = ", ".join(by_id.get(c["id"], c["id"]) for c in consumers)
        variables = paged(f"/workspaces/{wid}/vars", token)
        var_names = ", ".join(
            f"{v['attributes']['key']}"
            f"{' (sensitive)' if v['attributes']['sensitive'] else ''}"
            f"{' [env]' if v['attributes']['category'] == 'env' else ''}"
            for v in sorted(variables, key=lambda v: v["attributes"]["key"])
        )

        print(
            f"| {a['name']} | {a.get('resource-count')} | {a.get('terraform-version')} "
            f"| {a.get('auto-apply')} | `{a.get('working-directory') or ''}` "
            f"| {', '.join(a.get('trigger-prefixes') or [])} | {triggered_by} "
            f"| {consumer_names} | {var_names} |"
        )
    print()
    print(f"Total resources under management: {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
