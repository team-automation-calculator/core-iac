#!/usr/bin/env python3
"""Filter the public AWS Price List CSV for Amazon RDS into readable rows.

Read-only, offline. The staging CI role has no pricing:GetProducts permission, so the
plans under plans/ use the public bulk price list instead. Download it first into its
own scratch directory (gitignored tmp/):

    curl -s -o tmp/rds-pricelist/index.csv \
      https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/us-west-1/index.csv

then, for example:

    python3 -I scripts/rds_price_list_extract.py tmp/rds-pricelist/index.csv \
      --engine PostgreSQL --instance-type db.t4g.micro --term OnDemand
    python3 -I scripts/rds_price_list_extract.py tmp/rds-pricelist/index.csv \
      --family 'Database Storage' --engine PostgreSQL
    python3 -I scripts/rds_price_list_extract.py tmp/rds-pricelist/index.csv \
      --grep 'Serverless|ACU'

Every filter is optional; --grep is a case-insensitive regex over usageType,
PriceDescription and Product Family. The CSV has five preamble lines before the header.
"""

import argparse
import csv
import re
import sys

COLUMNS = [
    "TermType",
    "LeaseContractLength",
    "PurchaseOption",
    "Product Family",
    "Instance Type",
    "vCPU",
    "Memory",
    "Database Engine",
    "Deployment Option",
    "Volume Type",
    "usageType",
    "Unit",
    "PricePerUnit",
    "StartingRange",
    "EndingRange",
    "Normalization Size Factor",
    "PriceDescription",
]


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("csv_path")
    parser.add_argument("--term", help="OnDemand or Reserved")
    parser.add_argument("--family", help="Product Family, e.g. 'Database Instance'")
    parser.add_argument("--engine", help="Database Engine, e.g. PostgreSQL")
    parser.add_argument("--instance-type", help="e.g. db.t4g.micro")
    parser.add_argument("--deployment", help="Single-AZ or Multi-AZ")
    parser.add_argument("--volume-type", help="e.g. 'General Purpose-GP3'")
    parser.add_argument(
        "--grep", help="regex over usageType, PriceDescription, Product Family"
    )
    args = parser.parse_args()

    pattern = re.compile(args.grep, re.IGNORECASE) if args.grep else None
    with open(args.csv_path, newline="", encoding="utf-8") as handle:
        for _ in range(5):
            next(handle)
        reader = csv.DictReader(handle)
        count = 0
        for row in reader:
            if args.term and row["TermType"] != args.term:
                continue
            if args.family and row["Product Family"] != args.family:
                continue
            if args.engine and row["Database Engine"] != args.engine:
                continue
            if args.instance_type and row["Instance Type"] != args.instance_type:
                continue
            if args.deployment and row["Deployment Option"] != args.deployment:
                continue
            if args.volume_type and row["Volume Type"] != args.volume_type:
                continue
            if pattern and not (
                pattern.search(row["usageType"])
                or pattern.search(row["PriceDescription"])
                or pattern.search(row["Product Family"])
            ):
                continue
            count += 1
            print(" | ".join(row[c] for c in COLUMNS))
    print(f"-- {count} rows", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
