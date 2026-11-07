#!/usr/bin/env python3
"""Print us-west-1 Linux EC2 prices (on-demand, RI, Savings Plans) for worker node candidates.

Backs plans/ec2-worker-node-sizing.md. The staging CI role cannot call the AWS Pricing
or Savings Plans APIs, so this reads two public, unauthenticated price files that you
download first into the gitignored tmp/ directory (treat them as untrusted data and
run this with `python3 -I`):

    mkdir -p tmp/pricing
    curl -sS --compressed -o tmp/pricing/vantage_instances.json \
        https://instances.vantage.sh/instances.json
    # AWS Savings Plans price list: resolve the current us-west-1 version first
    curl -sS --compressed -o tmp/pricing/sp_region_index.json \
        https://pricing.us-east-1.amazonaws.com/savingsPlan/v1.0/aws/AWSComputeSavingsPlan/current/region_index.json
    # then fetch https://pricing.us-east-1.amazonaws.com<versionUrl for us-west-1>
    # into tmp/pricing/sp_us-west-1.json

    python3 -I scripts/ec2_worker_node_pricing.py \
        --vantage tmp/pricing/vantage_instances.json \
        --savings-plans tmp/pricing/sp_us-west-1.json \
        [--region us-west-1] [--hours 730] [--types t4g.medium,t4g.small,...]

The vantage file is the ec2instances.info dataset (derived from the AWS price list) and
carries per-region on-demand, Standard/Convertible RI and Savings Plan effective hourly
rates. The AWS Savings Plans file is used to cross-check the Savings Plan rates.
"""

import argparse
import json
import sys

DEFAULT_TYPES = [
    "t3.small",
    "t3.medium",
    "t3a.medium",
    "t4g.small",
    "t4g.medium",
    "t4g.large",
    "m6g.medium",
    "m7g.medium",
    "m8g.medium",
    "c7g.medium",
    "c8g.medium",
]

RI_KEYS = [
    ("1y Std no-up", "yrTerm1Standard.noUpfront"),
    ("1y Std partial", "yrTerm1Standard.partialUpfront"),
    ("1y Std all-up", "yrTerm1Standard.allUpfront"),
    ("3y Std no-up", "yrTerm3Standard.noUpfront"),
    ("3y Std partial", "yrTerm3Standard.partialUpfront"),
    ("3y Std all-up", "yrTerm3Standard.allUpfront"),
    ("1y Conv no-up", "yrTerm1Convertible.noUpfront"),
    ("1y Conv partial", "yrTerm1Convertible.partialUpfront"),
    ("1y Conv all-up", "yrTerm1Convertible.allUpfront"),
    ("3y Conv no-up", "yrTerm3Convertible.noUpfront"),
    ("3y Conv partial", "yrTerm3Convertible.partialUpfront"),
    ("3y Conv all-up", "yrTerm3Convertible.allUpfront"),
    ("1y Compute SP no-up", "yrTerm1Savings.noUpfront"),
    ("1y Compute SP partial", "yrTerm1Savings.partialUpfront"),
    ("1y Compute SP all-up", "yrTerm1Savings.allUpfront"),
    ("3y Compute SP no-up", "yrTerm3Savings.noUpfront"),
    ("3y Compute SP partial", "yrTerm3Savings.partialUpfront"),
    ("3y Compute SP all-up", "yrTerm3Savings.allUpfront"),
    ("1y EC2 Inst SP no-up", "yrTerm1InstanceSavings.noUpfront"),
    ("1y EC2 Inst SP partial", "yrTerm1InstanceSavings.partialUpfront"),
    ("1y EC2 Inst SP all-up", "yrTerm1InstanceSavings.allUpfront"),
    ("3y EC2 Inst SP no-up", "yrTerm3InstanceSavings.noUpfront"),
    ("3y EC2 Inst SP partial", "yrTerm3InstanceSavings.partialUpfront"),
    ("3y EC2 Inst SP all-up", "yrTerm3InstanceSavings.allUpfront"),
]


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def vantage_rows(data, region, types):
    rows = {}
    for item in data:
        itype = item.get("instance_type")
        if itype not in types:
            continue
        linux = item.get("pricing", {}).get(region, {}).get("linux")
        if not linux:
            print(f"warning: no {region} linux pricing for {itype}", file=sys.stderr)
            continue
        rows[itype] = {
            "vcpu": item.get("vCPU"),
            "memory": item.get("memory"),
            "generation": item.get("generation"),
            "ondemand": float(linux["ondemand"]),
            "reserved": {k: float(v) for k, v in linux.get("reserved", {}).items()},
            "spot_avg": linux.get("spot_avg"),
            "pct_interrupt": linux.get("pct_interrupt"),
        }
    return rows


def print_summary(rows, types, hours):
    print(f"On-demand, Linux, shared tenancy, {hours} h/month")
    print(
        f"{'type':12} {'vcpu':>4} {'mem GiB':>8} {'gen':>7} {'$/h':>8} {'$/mo':>7} {'$/yr':>7} {'spot avg':>9} {'interrupt':>10}"
    )
    for itype in types:
        r = rows.get(itype)
        if not r:
            continue
        od = r["ondemand"]
        print(
            f"{itype:12} {str(r['vcpu']):>4} {str(r['memory']):>8} {str(r['generation']):>7} "
            f"{od:8.4f} {od*hours:7.2f} {od*hours*12:7.2f} {str(r['spot_avg']):>9} {str(r['pct_interrupt']):>10}"
        )


def print_commitments(rows, types, hours):
    print()
    print(
        "Commitment pricing: effective $/h, $/month, total cost over the term, and % saved vs on-demand"
    )
    for itype in types:
        r = rows.get(itype)
        if not r:
            continue
        od = r["ondemand"]
        print()
        print(f"== {itype} (on-demand {od:.4f} $/h = {od*hours:.2f} $/mo)")
        for label, key in RI_KEYS:
            rate = r["reserved"].get(key)
            if rate is None:
                continue
            years = 3 if key.startswith("yrTerm3") else 1
            total = rate * hours * 12 * years
            pct = (1 - rate / od) * 100
            print(
                f"  {label:24} {rate:8.4f} $/h  {rate*hours:7.2f} $/mo  {total:8.2f} $/{years}y  -{pct:4.1f}%"
            )


def print_sp_crosscheck(sp_data, region, types):
    prefix = {"us-west-1": "USW1"}.get(region)
    if not prefix:
        print(
            f"no usage-type prefix known for {region}; skipping Savings Plans cross-check"
        )
        return
    wanted = {f"{prefix}-BoxUsage:{t}": t for t in types}
    print()
    print("AWS Savings Plans price list cross-check (Linux shared, BoxUsage):")
    found = []
    for term in sp_data.get("terms", {}).get("savingsPlan", []):
        desc = term.get("description", "")
        for rate in term.get("rates", []):
            itype = wanted.get(rate.get("discountedUsageType"))
            if itype:
                found.append((itype, desc, float(rate["discountedRate"]["price"])))
    for itype, desc, price in sorted(found):
        print(f"  {itype:12} {desc:48} {price:.4f} $/h")


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument(
        "--vantage", required=True, help="path to instances.vantage.sh instances.json"
    )
    parser.add_argument(
        "--savings-plans",
        help="path to the AWS Savings Plans price list for the region",
    )
    parser.add_argument("--region", default="us-west-1")
    parser.add_argument("--hours", type=float, default=730.0)
    parser.add_argument("--types", default=",".join(DEFAULT_TYPES))
    args = parser.parse_args()

    types = [t.strip() for t in args.types.split(",") if t.strip()]
    rows = vantage_rows(load_json(args.vantage), args.region, set(types))
    print_summary(rows, types, args.hours)
    print_commitments(rows, types, args.hours)
    if args.savings_plans:
        print_sp_crosscheck(load_json(args.savings_plans), args.region, types)
    return 0


if __name__ == "__main__":
    sys.exit(main())
