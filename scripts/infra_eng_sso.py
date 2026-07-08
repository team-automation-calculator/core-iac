#!/usr/bin/env python3
"""Log in to AWS via IAM Identity Center and set up kubectl access.

Manages the InfraEng SSO flow end to end for one environment:

1. Writes the required profiles to ~/.aws/config: an SSO profile for the
   InfraEng<Env> permission set, and a chained profile that assumes the
   environment's CI Terraform role (ac_ci_terraform_<env>). kubectl and
   Terraform must run as the CI role — it is the principal with the EKS
   access entry — so the chained profile is the one to use day to day.
2. Runs `aws sso login` (opens the browser device flow) to cache a local
   Identity Center token.
3. Updates the kubeconfig for the environment's EKS clusters with the
   chained profile embedded, so kubectl works without any shell setup.

A child process cannot set AWS_PROFILE in the calling shell, so to point
subsequent commands at the chained profile either eval the export line:

    eval "$(scripts/infra_eng_sso.py export --environment staging)"

or run the full flow and copy the printed export line:

    scripts/infra_eng_sso.py up --environment staging

First run needs --sso-start-url and --account-id; both are persisted in
~/.aws/config and read back on later runs. Runs on the standard library
plus the aws CLI (v2, for sso-session support).
"""

from __future__ import annotations

import argparse
import configparser
import re
import subprocess
import sys
from pathlib import Path

SSO_SESSION_NAME = "automation-calculator"
SSO_REGION = "us-east-1"  # Identity Center organization instance region
CLUSTER_REGION = "us-west-1"
ENVIRONMENTS = ["development", "staging", "production"]

AWS_CONFIG_PATH = Path.home() / ".aws" / "config"

SECTION_HEADER_RE = re.compile(r"^\s*\[[^\]]+\]\s*$")


def profile_names(environment: str, read_only: bool) -> tuple[str, str]:
    """Return (sso_profile, chained_ci_role_profile) for the environment."""
    suffix = "-ro" if read_only else ""
    return f"ac-{environment}-sso{suffix}", f"ac-{environment}{suffix}"


def permission_set_name(environment: str, read_only: bool) -> str:
    return f"InfraEng{environment.title()}{'ReadOnly' if read_only else ''}"


def ci_role_name(environment: str, read_only: bool) -> str:
    return f"ac_ci_terraform_{environment}{'_read_only' if read_only else ''}"


def read_config() -> configparser.ConfigParser:
    config = configparser.ConfigParser()
    if AWS_CONFIG_PATH.exists():
        config.read(AWS_CONFIG_PATH)
    return config


def upsert_section(config_text: str, header: str, body: dict[str, str]) -> str:
    """Replace or append one INI section, leaving the rest of the file as is.

    configparser cannot write here: round-tripping the whole file would drop
    the user's comments and reformat unrelated profiles.
    """
    lines = config_text.splitlines()
    section_lines = [f"[{header}]"] + [f"{key} = {value}" for key, value in body.items()]

    start = next(
        (i for i, line in enumerate(lines) if line.strip() == f"[{header}]"),
        None,
    )
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(section_lines)
    else:
        end = next(
            (i for i in range(start + 1, len(lines)) if SECTION_HEADER_RE.match(lines[i])),
            len(lines),
        )
        lines[start:end] = section_lines + ([""] if end < len(lines) else [])
    return "\n".join(lines) + "\n"


def persisted_value(config: configparser.ConfigParser, section: str, key: str) -> str | None:
    if config.has_section(section) and config.has_option(section, key):
        return config.get(section, key)
    return None


def discover_account_id(config: configparser.ConfigParser) -> str | None:
    """Find the account id from any previously configured ac-* SSO profile."""
    for section in config.sections():
        if section.startswith("profile ac-") and config.has_option(section, "sso_account_id"):
            return config.get(section, "sso_account_id")
    return None


def configure(environment: str, read_only: bool, sso_start_url: str | None, account_id: str | None) -> str:
    """Write the sso-session and profile chain; return the chained profile name."""
    config = read_config()

    sso_start_url = sso_start_url or persisted_value(
        config, f"sso-session {SSO_SESSION_NAME}", "sso_start_url"
    )
    account_id = account_id or discover_account_id(config)
    missing = [
        flag
        for flag, value in [("--sso-start-url", sso_start_url), ("--account-id", account_id)]
        if not value
    ]
    if missing or sso_start_url is None or account_id is None:
        sys.exit(
            f"error: {' and '.join(missing)} required on first run "
            "(persisted in ~/.aws/config afterwards)"
        )

    sso_profile, ci_profile = profile_names(environment, read_only)
    config_text = AWS_CONFIG_PATH.read_text() if AWS_CONFIG_PATH.exists() else ""

    config_text = upsert_section(
        config_text,
        f"sso-session {SSO_SESSION_NAME}",
        {
            "sso_start_url": sso_start_url,
            "sso_region": SSO_REGION,
            "sso_registration_scopes": "sso:account:access",
        },
    )
    config_text = upsert_section(
        config_text,
        f"profile {sso_profile}",
        {
            "sso_session": SSO_SESSION_NAME,
            "sso_account_id": account_id,
            "sso_role_name": permission_set_name(environment, read_only),
            "region": CLUSTER_REGION,
        },
    )
    config_text = upsert_section(
        config_text,
        f"profile {ci_profile}",
        {
            "role_arn": f"arn:aws:iam::{account_id}:role/{ci_role_name(environment, read_only)}",
            "source_profile": sso_profile,
            "region": CLUSTER_REGION,
        },
    )

    AWS_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    AWS_CONFIG_PATH.write_text(config_text)
    print(f"configured profiles {sso_profile} -> {ci_profile} in {AWS_CONFIG_PATH}")
    return ci_profile


def aws(*args: str, capture: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["aws", *args],
        check=True,
        capture_output=capture,
        text=True,
    )


def login(ci_profile: str) -> None:
    aws("sso", "login", "--sso-session", SSO_SESSION_NAME)
    identity = aws(
        "sts", "get-caller-identity", "--profile", ci_profile, "--output", "text",
        "--query", "Arn", capture=True,
    ).stdout.strip()
    print(f"logged in; {ci_profile} resolves to {identity}")


def update_kubeconfig(ci_profile: str) -> None:
    clusters = aws(
        "eks", "list-clusters", "--profile", ci_profile,
        "--region", CLUSTER_REGION, "--output", "text", "--query", "clusters",
        capture=True,
    ).stdout.split()
    if not clusters:
        print("no EKS clusters found in this account/region", file=sys.stderr)
        return
    for cluster in clusters:
        aws(
            "eks", "update-kubeconfig", "--name", cluster,
            "--profile", ci_profile, "--region", CLUSTER_REGION,
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "command",
        choices=["up", "configure", "login", "kubeconfig", "export"],
        help=(
            "up: configure + login + kubeconfig; "
            "export: print an eval-able AWS_PROFILE export line"
        ),
    )
    parser.add_argument("--environment", "-e", choices=ENVIRONMENTS, required=True)
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="use the InfraEng<Env>ReadOnly permission set and read-only CI role",
    )
    parser.add_argument("--sso-start-url", help="Identity Center start URL (first run only)")
    parser.add_argument("--account-id", help="AWS account id (first run only)")
    args = parser.parse_args()

    _, ci_profile = profile_names(args.environment, args.read_only)

    if args.command == "export":
        print(f"export AWS_PROFILE={ci_profile}")
        return 0

    if args.command in ("up", "configure"):
        configure(args.environment, args.read_only, args.sso_start_url, args.account_id)
    if args.command in ("up", "login"):
        login(ci_profile)
    if args.command in ("up", "kubeconfig"):
        update_kubeconfig(ci_profile)

    if args.command == "up":
        print(
            "\nto point subsequent aws/terraform commands at this environment:\n"
            f'  eval "$({Path(sys.argv[0])} export --environment {args.environment}'
            f'{" --read-only" if args.read_only else ""})"\n'
            "kubectl already works: the kubeconfig embeds the profile."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
