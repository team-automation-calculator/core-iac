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
3. Updates the kubeconfig entry for the environment's EKS cluster
   (ac_app_<env>) with the chained profile embedded, so kubectl works
   without any shell setup. Only that cluster's entry is touched: all
   environments share one AWS account, so updating every cluster in the
   account would stamp this environment's profile into the other
   environments' contexts and break them.
4. Switches the current kubectl context to the environment's cluster.
   The `context` command runs this step alone — use it to hop between
   environments that are already in the kubeconfig without any AWS calls.

A child process cannot set AWS_PROFILE in the calling shell, so `up` and
`login` print an eval-able export line for the chained profile as their
only stdout (all progress output goes to stderr). To log in and point the
current shell at the profile in one step:

    eval "$(scripts/infra_eng_sso.py up --environment staging)"

Without eval, copy the printed export line, or print it again any time with:

    eval "$(scripts/infra_eng_sso.py export --environment staging)"

First run needs --sso-start-url and --account-id; both are persisted in
~/.aws/config and read back on later runs. The start URL must be the AWS
access portal URL — https://<subdomain>.awsapps.com/start or the newer
https://ssoins-<id>.portal.<region>.app.aws — not the Identity Center
instance URL (https://identitycenter.amazonaws.com/ssoins-...) also shown
in the console. Runs on the standard library plus the aws CLI (v2, for
sso-session support).
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
# Short names used in AWS profile names (infra-eng-staging, ac-ci-dev, ...)
SHORT_ENV_NAMES = {"development": "dev", "staging": "staging", "production": "prod"}

AWS_CONFIG_PATH = Path.home() / ".aws" / "config"

SECTION_HEADER_RE = re.compile(r"^\s*\[[^\]]+\]\s*$")

# The documented sso_start_url value is the AWS access portal URL, in either
# the legacy form (https://<subdomain>.awsapps.com/start) or the newer form
# (https://ssoins-<id>.portal.<region>.app.aws). The Identity Center console
# also shows an instance/issuer URL
# (https://identitycenter.amazonaws.com/ssoins-...); logins with it can work,
# but it is not the documented start URL and diverges from the profile
# reference in docs/aws-sso-auth.md, so reject it before persisting.
PORTAL_URL_RES = (
    re.compile(r"^https://[a-z0-9.-]+\.awsapps\.com/start/?$"),
    re.compile(r"^https://ssoins-[a-z0-9]+\.portal\.[a-z0-9-]+\.app\.aws/?$"),
)
ACCOUNT_ID_RE = re.compile(r"^\d{12}$")


def validate_sso_start_url(sso_start_url: str) -> None:
    if any(pattern.match(sso_start_url) for pattern in PORTAL_URL_RES):
        return
    message = f"error: {sso_start_url!r} is not an AWS access portal URL"
    if "identitycenter.amazonaws.com" in sso_start_url:
        message += ":\nthis is the Identity Center instance (issuer) URL, not the portal URL"
    sys.exit(
        message
        + "\nexpected form: https://<subdomain>.awsapps.com/start"
        + "\n            or https://ssoins-<id>.portal.<region>.app.aws"
        + "\n(Identity Center console -> Settings -> AWS access portal URL;"
        + "\nre-run configure with --sso-start-url to replace a persisted value)"
    )


def profile_names(environment: str, read_only: bool) -> tuple[str, str]:
    """Return (sso_profile, chained_ci_role_profile) for the environment."""
    short = SHORT_ENV_NAMES[environment]
    suffix = "-ro" if read_only else ""
    return f"infra-eng-{short}{suffix}", f"ac-ci-{short}{suffix}"


def cluster_name(environment: str) -> str:
    # Matches the EKS cluster name set in terraform/modules/aws/base-cluster-layer.
    return f"ac_app_{environment}"


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
    """Find the account id from any previously configured InfraEng SSO profile."""
    for section in config.sections():
        if section.startswith("profile infra-eng-") and config.has_option(section, "sso_account_id"):
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
    validate_sso_start_url(sso_start_url)
    if not ACCOUNT_ID_RE.match(account_id):
        sys.exit(f"error: account id must be 12 digits, got {account_id!r}")

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
    print(f"configured profiles {sso_profile} -> {ci_profile} in {AWS_CONFIG_PATH}", file=sys.stderr)
    return ci_profile


def aws(*args: str, capture: bool = False) -> subprocess.CompletedProcess:
    if capture:
        return subprocess.run(["aws", *args], check=True, text=True, capture_output=True)
    # Uncaptured aws output (login prompts, kubeconfig updates) goes to
    # stderr: stdout is reserved for the eval-able AWS_PROFILE export line.
    return subprocess.run(["aws", *args], check=True, text=True, stdout=sys.stderr)


def login(ci_profile: str) -> None:
    try:
        aws("sso", "login", "--sso-session", SSO_SESSION_NAME)
    except subprocess.CalledProcessError as error:
        sys.exit(
            f"error: aws sso login exited with status {error.returncode}\n"
            'if the browser showed "Something doesn\'t compute - We couldn\'t verify\n'
            'your sign-in credentials", the local config is usually not the problem:\n'
            "that page comes from stale AWS sign-in state in the browser or from\n"
            "federating the wrong Google account. Retry in a private window and pick\n"
            "your Workspace account, or clear cookies for awsapps.com and\n"
            "signin.aws.amazon.com. See docs/aws-sso-auth.md#troubleshooting."
        )
    identity = aws(
        "sts", "get-caller-identity", "--profile", ci_profile, "--output", "text",
        "--query", "Arn", capture=True,
    ).stdout.strip()
    print(f"logged in; {ci_profile} resolves to {identity}", file=sys.stderr)


def kubectl(*args: str, capture: bool = False) -> subprocess.CompletedProcess:
    try:
        if capture:
            return subprocess.run(["kubectl", *args], check=True, text=True, capture_output=True)
        # Like aws(): uncaptured output goes to stderr, stdout stays eval-able.
        return subprocess.run(["kubectl", *args], check=True, text=True, stdout=sys.stderr)
    except FileNotFoundError:
        sys.exit("error: kubectl not found on PATH")


def update_kubeconfig(ci_profile: str, environment: str) -> None:
    """Update the kubeconfig entry for this environment's cluster only.

    All environments live in one AWS account, so updating every cluster
    list-clusters returns would embed this environment's profile into the
    other environments' contexts and break their kubectl auth.
    """
    cluster = cluster_name(environment)
    try:
        aws(
            "eks", "update-kubeconfig", "--name", cluster,
            "--profile", ci_profile, "--region", CLUSTER_REGION,
        )
    except subprocess.CalledProcessError as error:
        sys.exit(
            f"error: aws eks update-kubeconfig for cluster {cluster} "
            f"exited with status {error.returncode}"
        )


def use_context(environment: str) -> None:
    """Point kubectl's current context at this environment's cluster."""
    cluster = cluster_name(environment)
    contexts = kubectl("config", "get-contexts", "-o", "name", capture=True).stdout.split()
    matches = [c for c in contexts if c == cluster or c.endswith(f"/{cluster}")]
    if not matches:
        sys.exit(
            f"error: no kubeconfig context found for cluster {cluster}; "
            f"run `{sys.argv[0]} kubeconfig --environment {environment}` first"
        )
    kubectl("config", "use-context", matches[0])


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "command",
        choices=["up", "configure", "login", "kubeconfig", "context", "export"],
        help=(
            "up: configure + login + kubeconfig + context; "
            "kubeconfig: update the env's cluster entry and switch context; "
            "context: switch kubectl's current context to the env's cluster (no AWS calls); "
            "up, login, and export print an eval-able AWS_PROFILE export line"
        ),
    )
    parser.add_argument("--environment", "-e", choices=list(SHORT_ENV_NAMES), required=True)
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="use the InfraEng<Env>ReadOnly permission set and read-only CI role",
    )
    parser.add_argument(
        "--sso-start-url",
        help=(
            "AWS access portal URL, https://<subdomain>.awsapps.com/start or "
            "https://ssoins-<id>.portal.<region>.app.aws — not the "
            "identitycenter.amazonaws.com instance URL (first run only)"
        ),
    )
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
        update_kubeconfig(ci_profile, args.environment)
    if args.command in ("up", "kubeconfig", "context"):
        use_context(args.environment)

    if args.command in ("up", "login"):
        hint = (
            "\nexport line follows on stdout; to adopt the profile in the "
            "current shell,\nrun this command as "
            f'eval "$({Path(sys.argv[0])} ...)" or copy the line below.'
        )
        if args.command == "up":
            hint += (
                "\nkubectl already works: the kubeconfig embeds the profile and "
                f"the current context\npoints at {cluster_name(args.environment)}."
            )
        print(hint + "\n", file=sys.stderr)
        print(f"export AWS_PROFILE={ci_profile}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
