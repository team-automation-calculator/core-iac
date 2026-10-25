#!/usr/bin/env python3
"""Migrate external-dns TXT ownership records to a --txt-prefix layout.

external-dns (txt registry) proves ownership of each DNS record with a TXT
record. Without a prefix, the TXT name for host `a.b.c` and type token `t` is
`t-a.b.c`; for the zone apex `automation-calculations.io` that becomes
`cname-automation-calculations.io`, which is outside the hosted zone, so the
record can never be written and external-dns force-UPSERTs the apex A record
on every sync. Setting the prefix `%{record_type}-extdns.` moves the TXT
names to `t-extdns.a.b.c`, which is always inside the zone.

Once the prefix is live, external-dns no longer recognises the old TXT names
and treats every record as unowned: with policy upsert-only it then silently
skips all updates, freezing DNS. So the new-format TXT records must exist
BEFORE the prefix is applied. This script handles that, one environment at a
time (see docs/external-dns-txt-prefix-migration.md for the full runbook):

    plan        read-only: show current ownership TXT records for the
                environment's hosts and what create-new / delete-old would do
    create-new  CREATE the prefixed TXT records, copying the value and TTL
                from the existing ownership record for the same host
    delete-old  remove the old-format TXT records (only after the prefix is
                live and verified); refuses unless every new record exists

Writes are dry runs unless --apply is given; a dry run prints the Route 53
change batch and the inverse batch that would undo it. Hosts come from
automation_calculator_app_host in the environment's cluster-addons-layer
terraform.tfvars plus its `www.` alias, matching the Helm ingress.

Profiles default to the chained CI role profiles written by
scripts/infra_eng_sso.py: ac-ci-<env>-ro for plan, ac-ci-<env> for writes.
Runs on the standard library plus the aws CLI.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HOSTED_ZONE_ID = "Z0212130UA03VYHTN72T"  # automation-calculations.io. (public)
TXT_PREFIX = "%{record_type}-extdns."
RECORD_TYPE_TEMPLATE = "%{record_type}"
OWNER_ID = "default"
HERITAGE = "heritage=external-dns"
SHORT_ENV_NAMES = {"staging": "staging", "production": "prod"}

REPO_ROOT = Path(__file__).resolve().parent.parent
APP_HOST_RE = re.compile(
    r'^\s*automation_calculator_app_host\s*=\s*"([^"]+)"\s*$', re.M
)


def tfvars_path(environment: str) -> Path:
    return (
        REPO_ROOT
        / "terraform/env"
        / environment
        / "aws/us-west-1/cluster-addons-layer/terraform.tfvars"
    )


def env_hosts(environment: str) -> list[str]:
    """The ingress hosts for the environment: the app host and its www alias."""
    path = tfvars_path(environment)
    match = APP_HOST_RE.search(path.read_text())
    if not match:
        sys.exit(f"error: automation_calculator_app_host not found in {path}")
    host = normalize(match.group(1))
    return [host, f"www.{host}"]


def normalize(name: str) -> str:
    """Lowercase and strip the trailing dot Route 53 puts on names."""
    return name.lower().rstrip(".")


def to_txt_name(dns_name: str, token: str, prefix: str) -> str:
    """Port of AffixNameMapper.ToTXTName (external-dns v0.21.0, prefix only).

    `token` is the lowercased record type external-dns encodes: "cname" for
    alias A records, "a" for plain A, "aaaa" for AAAA.
    """
    labels = dns_name.split(".", 1)
    resolved_prefix = prefix.replace(RECORD_TYPE_TEMPLATE, token)
    if RECORD_TYPE_TEMPLATE not in prefix:
        labels[0] = f"{token}-{labels[0]}"
    if len(labels) < 2:
        return resolved_prefix + labels[0]
    return f"{resolved_prefix}{labels[0]}.{labels[1]}"


def aws(profile: str, *args: str) -> str:
    try:
        return subprocess.run(
            ["aws", *args, "--profile", profile, "--output", "json"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout
    except FileNotFoundError:
        sys.exit("error: aws CLI not found on PATH")
    except subprocess.CalledProcessError as error:
        sys.exit(
            f"error: aws {' '.join(args[:2])} exited with status {error.returncode}:\n"
            f"{error.stderr.strip()}"
        )


def list_records(profile: str, zone_id: str) -> list[dict]:
    """All record sets in the zone (the CLI paginates automatically)."""
    output = aws(
        profile,
        "route53",
        "list-resource-record-sets",
        "--hosted-zone-id",
        zone_id,
    )
    return json.loads(output)["ResourceRecordSets"]


def is_ownership_value(value: str) -> bool:
    return HERITAGE in value


def owner_of(value: str) -> str | None:
    match = re.search(r"external-dns/owner=([^,\"]+)", value)
    return match.group(1) if match else None


@dataclass
class TxtRecord:
    name: str
    ttl: int
    values: list[str]

    @property
    def ownership_values(self) -> list[str]:
        return [v for v in self.values if is_ownership_value(v)]

    def to_rrset(self, values: list[str] | None = None) -> dict:
        return {
            "Name": f"{self.name}.",
            "Type": "TXT",
            "TTL": self.ttl,
            "ResourceRecords": [{"Value": v} for v in (values or self.values)],
        }


@dataclass
class HostPlan:
    host: str
    tokens: list[str]
    # old-format TXT names that exist for this host, in lookup order
    old: list[TxtRecord]
    # new name -> existing record (or None)
    new: dict[str, TxtRecord | None]
    # value/TTL to copy into new records
    source: TxtRecord | None


def tokens_for_host(records: list[dict], host: str) -> list[str]:
    """Record type tokens external-dns uses for the host's managed records."""
    tokens = []
    for record in records:
        if normalize(record["Name"]) != host:
            continue
        if record["Type"] == "A":
            tokens.append("cname" if "AliasTarget" in record else "a")
        elif record["Type"] == "AAAA":
            tokens.append("aaaa")
        elif record["Type"] == "CNAME":
            tokens.append("cname")
    return sorted(set(tokens))


def build_plan(records: list[dict], hosts: list[str]) -> list[HostPlan]:
    txt = {
        normalize(r["Name"]): TxtRecord(
            name=normalize(r["Name"]),
            ttl=r["TTL"],
            values=[rr["Value"] for rr in r["ResourceRecords"]],
        )
        for r in records
        if r["Type"] == "TXT"
    }
    plans = []
    for host in hosts:
        tokens = tokens_for_host(records, host)
        if not tokens:
            sys.exit(f"error: no A/AAAA/CNAME records found for {host}")
        # Old names: new-format without prefix first (preferred source), then
        # the legacy pre-v0.12 TXT at the host name itself.
        old_names = [to_txt_name(host, t, "") for t in tokens] + [host]
        old = [
            txt[name]
            for name in old_names
            if name in txt and txt[name].ownership_values
        ]
        new = {to_txt_name(host, t, TXT_PREFIX): None for t in tokens}
        for name in new:
            new[name] = txt.get(name)
        source = next(
            (r for r in old if owner_of(r.ownership_values[0]) == OWNER_ID), None
        )
        plans.append(HostPlan(host, tokens, old, new, source))
    return plans


def new_value(plan: HostPlan) -> str:
    if plan.source is None:
        sys.exit(
            f"error: no ownership TXT record with owner={OWNER_ID} found for "
            f"{plan.host}; refusing to invent one"
        )
    return plan.source.ownership_values[0]


def print_plan(environment: str, plans: list[HostPlan]) -> None:
    print(f"environment: {environment}  zone: {HOSTED_ZONE_ID}  prefix: {TXT_PREFIX}")
    for plan in plans:
        print(f"\n{plan.host}  (record type tokens: {', '.join(plan.tokens)})")
        print("  current ownership TXT records (delete-old candidates):")
        if not plan.old:
            print("    (none)")
        for record in plan.old:
            for value in record.ownership_values:
                print(f"    {record.name}  TTL {record.ttl}  {value}")
            others = len(record.values) - len(record.ownership_values)
            if others:
                print(f"      + {others} non-external-dns value(s), kept on delete")
        print("  new-format TXT records:")
        for name, existing in plan.new.items():
            if existing is None:
                status = "MISSING -> create-new"
            elif plan.source and new_value(plan) in existing.values:
                status = "present, value matches"
            else:
                status = "present, VALUE DIFFERS"
            print(f"    {name}  {status}")
        if plan.source:
            print(f"  value source: {plan.source.name} (TTL {plan.source.ttl})")
        else:
            print(
                f"  value source: NONE (no owner={OWNER_ID} record) - create-new would fail"
            )


def create_changes(plans: list[HostPlan]) -> tuple[list[dict], list[dict]]:
    changes, inverse = [], []
    for plan in plans:
        value = new_value(plan)
        for name, existing in plan.new.items():
            if existing is not None:
                if existing.values == [value]:
                    continue
                sys.exit(
                    f"error: {name} already exists with a different value:\n"
                    f"  {existing.values}\nexpected [{value!r}]; resolve by hand"
                )
            rrset = TxtRecord(name, plan.source.ttl, [value]).to_rrset()
            changes.append({"Action": "CREATE", "ResourceRecordSet": rrset})
            inverse.append({"Action": "DELETE", "ResourceRecordSet": rrset})
    return changes, inverse


def delete_changes(plans: list[HostPlan]) -> tuple[list[dict], list[dict]]:
    changes, inverse = [], []
    for plan in plans:
        value = new_value(plan)
        not_ready = [
            name
            for name, existing in plan.new.items()
            if existing is None or value not in existing.values
        ]
        if not_ready:
            sys.exit(
                "error: refusing to delete old TXT records while new-format "
                f"records are missing or differ: {', '.join(not_ready)}\n"
                "run create-new first"
            )
        for record in plan.old:
            remaining = [
                v
                for v in record.values
                if not (is_ownership_value(v) and owner_of(v) == OWNER_ID)
            ]
            if remaining == record.values:
                continue
            current = record.to_rrset()
            if remaining:
                # Shared RRset (e.g. SPF at the apex): drop only our value.
                # UPSERT replaces the whole RRset with the remaining values.
                changes.append(
                    {
                        "Action": "UPSERT",
                        "ResourceRecordSet": record.to_rrset(remaining),
                    }
                )
                inverse.append({"Action": "UPSERT", "ResourceRecordSet": current})
            else:
                # DELETE must match the live RRset exactly (TTL and values).
                changes.append({"Action": "DELETE", "ResourceRecordSet": current})
                inverse.append({"Action": "CREATE", "ResourceRecordSet": current})
    return changes, inverse


def apply_changes(
    profile: str,
    zone_id: str,
    comment: str,
    changes: list[dict],
    inverse: list[dict],
    apply: bool,
) -> None:
    if not changes:
        print("\nnothing to do: all records already in the desired state")
        return
    batch = {"Comment": comment, "Changes": changes}
    undo = {"Comment": f"undo: {comment}", "Changes": inverse}
    print("\nchange batch:")
    print(json.dumps(batch, indent=2))
    print("\ninverse batch (save this; it undoes the change):")
    print(json.dumps(undo, indent=2))
    if not apply:
        print(
            f"\ndry run: nothing written. Re-run with --apply (profile {profile}) to apply."
        )
        return
    result = json.loads(
        aws(
            profile,
            "route53",
            "change-resource-record-sets",
            "--hosted-zone-id",
            zone_id,
            "--change-batch",
            json.dumps(batch),
        )
    )
    change_id = result["ChangeInfo"]["Id"]
    print(f"\nsubmitted {change_id}; waiting for INSYNC...")
    aws(profile, "route53", "wait", "resource-record-sets-changed", "--id", change_id)
    print("done: change is INSYNC")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("command", choices=["plan", "create-new", "delete-old"])
    parser.add_argument(
        "--environment", "-e", choices=list(SHORT_ENV_NAMES), required=True
    )
    parser.add_argument(
        "--profile",
        help="AWS profile (default: ac-ci-<env>-ro for plan, ac-ci-<env> for writes)",
    )
    parser.add_argument("--hosted-zone-id", default=HOSTED_ZONE_ID)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually write to Route 53 (default is a dry run)",
    )
    args = parser.parse_args()

    short = SHORT_ENV_NAMES[args.environment]
    read_only = args.command == "plan"
    profile = args.profile or f"ac-ci-{short}{'-ro' if read_only else ''}"
    if read_only and args.apply:
        sys.exit("error: --apply has no effect on plan")

    hosts = env_hosts(args.environment)
    plans = build_plan(list_records(profile, args.hosted_zone_id), hosts)
    print_plan(args.environment, plans)

    if args.command == "create-new":
        changes, inverse = create_changes(plans)
        comment = f"external-dns txt prefix migration: create new-format TXT ({args.environment})"
    elif args.command == "delete-old":
        print(
            "\nnote: only run delete-old once the prefix is live in this environment's\n"
            "external-dns and verified (see the runbook); before that, the old\n"
            "records are the only ones the running instance recognises."
        )
        changes, inverse = delete_changes(plans)
        comment = f"external-dns txt prefix migration: delete old-format TXT ({args.environment})"
    else:
        missing = sum(1 for p in plans for r in p.new.values() if r is None)
        old_count = sum(len(p.old) for p in plans)
        print(f"\ncreate-new would CREATE {missing} record(s)")
        print(
            f"delete-old would remove the owner={OWNER_ID} value from {old_count} record set(s)"
        )
        return 0
    apply_changes(profile, args.hosted_zone_id, comment, changes, inverse, args.apply)
    return 0


if __name__ == "__main__":
    sys.exit(main())
