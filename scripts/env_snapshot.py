#!/usr/bin/env python3
"""Snapshot an environment's observable state before and after an infra rollout, and diff two snapshots.

Usage:
    python3 -I scripts/env_snapshot.py take staging tmp/<pr>/staging-before
    python3 -I scripts/env_snapshot.py take production tmp/<pr>/production-before [--context CTX] [--profile P]
    python3 -I scripts/env_snapshot.py diff tmp/<pr>/staging-before tmp/<pr>/staging-after

`take` runs only reads (helm list / get manifest, kubectl get pods, Route 53 list, ACM describe,
GET /health) under the environment's read-only persona and writes one file per check into the
output directory. A check that fails is recorded in errors.txt and the others still run.
`diff` prints what changed between two snapshot directories: Helm revisions and chart versions,
rendered manifests, the host's Route 53 records, pods, the ACM certificate and /health.
"""

import argparse
import difflib
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime

ENVS = {
    "staging": {
        "host": "staging.automation-calculations.io",
        "profile": "ac-ci-staging-ro",
        "contexts": [
            "ac_app_staging-ro",
            "arn:aws:eks:us-west-1:030153300357:cluster/ac_app_staging",
        ],
    },
    "production": {
        "host": "automation-calculations.io",
        "profile": "ac-ci-prod-ro",
        "contexts": [
            "ac_app_production-ro",
            "arn:aws:eks:us-west-1:030153300357:cluster/ac_app_production",
        ],
    },
}
ZONE_NAME = "automation-calculations.io"
REGION = "us-west-1"
NAMESPACES = ["automation-calculator", "kube-system", "default"]


def run(cmd: list[str], env: dict) -> str:
    return subprocess.run(
        cmd, check=True, capture_output=True, text=True, env=env
    ).stdout


def pick_context(candidates: list[str]) -> str:
    names = subprocess.run(
        ["kubectl", "config", "get-contexts", "-o", "name"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.split()
    for c in candidates:
        if c in names:
            return c
    return ""


def kube_identity(ctx: str, env: dict) -> str:
    """Return the username the API server sees for this context ("" if the call fails).

    A kubeconfig context embeds the AWS profile it was created with, so the alias
    `ac_app_<env>-ro` proves nothing: it has been seen pointing at the read-write
    role. The identity is what matters.
    """
    try:
        data = json.loads(
            run(["kubectl", "auth", "whoami", "-o", "json", "--context", ctx], env)
        )
    except (subprocess.CalledProcessError, ValueError):
        return ""
    return data.get("status", {}).get("userInfo", {}).get("username", "")


def take(args: argparse.Namespace) -> int:
    import os

    cfg = ENVS[args.env]
    host = args.host or cfg["host"]
    profile = args.profile or cfg["profile"]
    ctx = args.context or pick_context(cfg["contexts"])
    out = pathlib.Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, AWS_PROFILE=profile)
    errors: list[str] = []

    identity = kube_identity(ctx, env) if ctx else ""
    if ctx and "_read_only/" not in identity:
        print(
            f"error: kubectl context {ctx} authenticates as {identity or 'unknown'}, not a "
            f"_read_only role; it embeds the wrong AWS profile. Recreate it with\n"
            f"  aws eks update-kubeconfig --name ac_app_{args.env} --region {REGION} "
            f"--profile {cfg['profile']} --alias ac_app_{args.env}-ro\n"
            f"or pass --context for a context that uses {cfg['profile']}.",
            file=sys.stderr,
        )
        return 2

    def step(name: str, fn) -> None:
        try:
            fn()
            print(f"ok    {name}")
        except Exception as exc:  # noqa: BLE001 - every check is independent
            msg = f"{name}: {type(exc).__name__}: {str(exc).strip()[:300]}"
            if isinstance(exc, subprocess.CalledProcessError):
                msg += f" :: {exc.stderr.strip()[:300]}"
            errors.append(msg)
            print(f"FAIL  {msg}")

    meta = {
        "env": args.env,
        "host": host,
        "profile": profile,
        "context": ctx,
        "identity": identity,
        "taken_at": datetime.now(UTC).isoformat(timespec="seconds"),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")

    def helm_list() -> None:
        if not ctx:
            raise RuntimeError("no kubectl context for this environment")
        text = run(["helm", "list", "-A", "-o", "json", "--kube-context", ctx], env)
        (out / "helm-list.json").write_text(text)
        (out / "manifests").mkdir(exist_ok=True)
        for rel in json.loads(text):
            manifest = run(
                [
                    "helm",
                    "get",
                    "manifest",
                    rel["name"],
                    "-n",
                    rel["namespace"],
                    "--kube-context",
                    ctx,
                ],
                env,
            )
            (out / "manifests" / f"{rel['namespace']}__{rel['name']}.yaml").write_text(
                manifest
            )

    def pods() -> None:
        if not ctx:
            raise RuntimeError("no kubectl context for this environment")
        rows = []
        for ns in NAMESPACES:
            data = json.loads(
                run(
                    [
                        "kubectl",
                        "get",
                        "pods",
                        "-n",
                        ns,
                        "-o",
                        "json",
                        "--context",
                        ctx,
                    ],
                    env,
                )
            )
            for p in data["items"]:
                statuses = p["status"].get("containerStatuses", [])
                rows.append(
                    {
                        "namespace": ns,
                        "name": p["metadata"]["name"],
                        "created": p["metadata"]["creationTimestamp"],
                        "phase": p["status"].get("phase"),
                        "node": p["spec"].get("nodeName"),
                        "images": [c["image"] for c in p["spec"]["containers"]],
                        "restarts": sum(s.get("restartCount", 0) for s in statuses),
                        "resources": [
                            c.get("resources", {}) for c in p["spec"]["containers"]
                        ],
                    }
                )
        (out / "pods.json").write_text(json.dumps(rows, indent=2) + "\n")

    def route53() -> None:
        zone = run(
            [
                "aws",
                "route53",
                "list-hosted-zones-by-name",
                "--dns-name",
                ZONE_NAME,
                "--query",
                "HostedZones[0].Id",
                "--output",
                "text",
            ],
            env,
        ).strip()
        text = run(
            [
                "aws",
                "route53",
                "list-resource-record-sets",
                "--hosted-zone-id",
                zone,
                "--output",
                "json",
            ],
            env,
        )
        (out / "route53-zone.json").write_text(text)
        suffix = "." + host + "."
        mine = [
            r
            for r in json.loads(text)["ResourceRecordSets"]
            if r["Name"] == host + "." or r["Name"].endswith(suffix)
        ]
        (out / "route53-host.json").write_text(json.dumps(mine, indent=2) + "\n")

    def acm() -> None:
        certs = json.loads(
            run(
                [
                    "aws",
                    "acm",
                    "list-certificates",
                    "--region",
                    REGION,
                    "--output",
                    "json",
                ],
                env,
            )
        )["CertificateSummaryList"]
        matches = [c for c in certs if c["DomainName"] == host]
        if not matches:
            raise RuntimeError(f"no ACM certificate with DomainName {host}")
        detail = json.loads(
            run(
                [
                    "aws",
                    "acm",
                    "describe-certificate",
                    "--region",
                    REGION,
                    "--output",
                    "json",
                    "--certificate-arn",
                    matches[0]["CertificateArn"],
                ],
                env,
            )
        )["Certificate"]
        keep = {
            k: detail.get(k)
            for k in (
                "CertificateArn",
                "DomainName",
                "Status",
                "NotAfter",
                "RenewalEligibility",
            )
        }
        keep["DomainValidationOptions"] = [
            {
                "DomainName": o["DomainName"],
                "ValidationStatus": o.get("ValidationStatus"),
                "ResourceRecord": o.get("ResourceRecord"),
            }
            for o in detail.get("DomainValidationOptions", [])
        ]
        (out / "acm.json").write_text(json.dumps(keep, indent=2, default=str) + "\n")

    def health() -> None:
        req = urllib.request.Request(
            f"https://{host}/health", headers={"User-Agent": "env_snapshot"}
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                status, body = resp.status, resp.read().decode()
        except urllib.error.HTTPError as exc:
            status, body = exc.code, exc.read().decode()
        (out / "health.json").write_text(
            json.dumps({"status": status, "body": body}, indent=2) + "\n"
        )

    for name, fn in [
        ("helm", helm_list),
        ("pods", pods),
        ("route53", route53),
        ("acm", acm),
        ("health", health),
    ]:
        step(name, fn)

    (out / "errors.txt").write_text("\n".join(errors) + ("\n" if errors else ""))
    print(f"snapshot written to {out} ({len(errors)} check(s) failed)")
    return 0


def load(d: pathlib.Path, name: str):
    p = d / name
    return json.loads(p.read_text()) if p.exists() else None


def diff(args: argparse.Namespace) -> int:
    before, after = pathlib.Path(args.before), pathlib.Path(args.after)
    mb, ma = load(before, "meta.json") or {}, load(after, "meta.json") or {}
    print(
        f"before: {mb.get('taken_at')}  after: {ma.get('taken_at')}  env: {ma.get('env')}"
    )

    print("\n## Helm releases")
    hb = {(r["namespace"], r["name"]): r for r in load(before, "helm-list.json") or []}
    ha = {(r["namespace"], r["name"]): r for r in load(after, "helm-list.json") or []}
    for key in sorted(set(hb) | set(ha)):
        b, a = hb.get(key), ha.get(key)
        if b and a:
            flag = (
                "same"
                if (b["revision"], b["chart"], b["status"])
                == (a["revision"], a["chart"], a["status"])
                else "CHANGED"
            )
            print(
                f"{flag:8} {key[0]}/{key[1]}: rev {b['revision']} -> {a['revision']}, chart {b['chart']} -> {a['chart']}, {b['status']} -> {a['status']}"
            )
        else:
            print(f"{'ADDED' if a else 'REMOVED':8} {key[0]}/{key[1]}")

    print("\n## Rendered manifests")
    files = sorted(
        {p.name for d in (before, after) for p in (d / "manifests").glob("*.yaml")}
        if (before / "manifests").exists()
        else set()
    )
    for f in files:
        pb, pa = before / "manifests" / f, after / "manifests" / f
        if not (pb.exists() and pa.exists()):
            print(f"{'only in after' if pa.exists() else 'only in before'}: {f}")
            continue
        lines = list(
            difflib.unified_diff(
                pb.read_text().splitlines(),
                pa.read_text().splitlines(),
                str(pb),
                str(pa),
                lineterm="",
            )
        )
        if not lines:
            print(f"identical {f}")
        else:
            print(
                f"CHANGED   {f} ({sum(1 for l in lines if l[:1] in '+-' and l[:3] not in ('+++', '---'))} changed lines)"
            )
            for l in lines[: args.max_lines]:
                print("    " + l)
            if len(lines) > args.max_lines:
                print(
                    f"    ... {len(lines) - args.max_lines} more lines; diff the files directly"
                )

    print("\n## Route 53 records for the host")
    rb = {
        json.dumps(r, sort_keys=True) for r in load(before, "route53-host.json") or []
    }
    ra = {json.dumps(r, sort_keys=True) for r in load(after, "route53-host.json") or []}
    if rb == ra:
        print(f"identical ({len(ra)} records)")
    for r in sorted(rb - ra):
        print("REMOVED " + r)
    for r in sorted(ra - rb):
        print("ADDED   " + r)

    print("\n## Pods")
    pb_ = {(p["namespace"], p["name"]): p for p in load(before, "pods.json") or []}
    pa_ = {(p["namespace"], p["name"]): p for p in load(after, "pods.json") or []}
    for key in sorted(set(pb_) | set(pa_)):
        b, a = pb_.get(key), pa_.get(key)
        if b and a:
            flag = (
                "same"
                if (b["restarts"], b["images"], b["phase"], b["resources"])
                == (a["restarts"], a["images"], a["phase"], a["resources"])
                else "CHANGED"
            )
            print(
                f"{flag:8} {key[0]}/{key[1]}: {a['phase']}, restarts {b['restarts']} -> {a['restarts']}, images {a['images']}"
            )
        elif a:
            print(
                f"NEW      {key[0]}/{key[1]}: {a['phase']}, restarts {a['restarts']}, images {a['images']}, resources {a['resources']}"
            )
        else:
            print(f"GONE     {key[0]}/{key[1]}")

    print("\n## ACM certificate")
    cb, ca = load(before, "acm.json"), load(after, "acm.json")
    if cb and ca:
        print(
            f"status {cb['Status']} -> {ca['Status']}, NotAfter {ca['NotAfter']}, renewal {ca['RenewalEligibility']}"
        )
        print(
            "validation records "
            + (
                "identical"
                if cb["DomainValidationOptions"] == ca["DomainValidationOptions"]
                else "CHANGED"
            )
        )
    else:
        print("not captured on one side")

    print("\n## /health")
    for label, d in (("before", before), ("after", after)):
        h = load(d, "health.json")
        print(
            f"{label}: "
            + (f"HTTP {h['status']} {h['body'].strip()[:200]}" if h else "not captured")
        )

    for label, d in (("before", before), ("after", after)):
        p = d / "errors.txt"
        if p.exists() and p.read_text().strip():
            print(f"\n## checks that failed in {label}\n" + p.read_text())
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("take", help="write a snapshot of one environment")
    t.add_argument("env", choices=sorted(ENVS))
    t.add_argument("outdir")
    t.add_argument(
        "--context", help="kubectl context (default: the env's -ro context if present)"
    )
    t.add_argument("--profile", help="AWS profile (default: the env's -ro CI profile)")
    t.add_argument("--host", help="app host (default per env)")
    t.set_defaults(fn=take)
    d = sub.add_parser("diff", help="compare two snapshot directories")
    d.add_argument("before")
    d.add_argument("after")
    d.add_argument(
        "--max-lines",
        type=int,
        default=80,
        help="manifest diff lines to print per release",
    )
    d.set_defaults(fn=diff)
    args = parser.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
