#!/usr/bin/env python3
"""Open psql on an environment's app database as one of its read-only roles.

    python3 -I scripts/db_read_only_psql.py staging --as infra-eng
    python3 -I scripts/db_read_only_psql.py staging --as ci -- -c "select count(*) from users"
    python3 -I scripts/db_read_only_psql.py production --as ci -- -At -f tmp/query.sql

There are two roles per environment, so the PostgreSQL log shows who ran what:

    --as infra-eng   ac_read_only_infra_eng_<env>   a person, through the InfraEng<Env>ReadOnly
                                                    permission set (profile infra-eng-<env>-ro)
    --as ci          ac_read_only_ci_<env>          CI and agents, through the read-only CI role
                                                    (profile ac-ci-<env>-ro)

Both can SELECT from the app's tables and nothing else. Neither has a password: the script asks
AWS for a 15-minute IAM token under the persona's profile, port-forwards to the forwarder pod
under the read-only kube context (ac_app_<env>-ro), and runs psql through it with full TLS
verification of the RDS endpoint. Everything after `--` goes to psql.

Needs `aws`, `kubectl` and `psql` (macOS: `brew install libpq`, then put its bin on PATH) and an
`aws sso login`. Reference: docs/db-read-only-access.md.
"""

import argparse
import json
import logging
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

logger = logging.getLogger("db_read_only_psql")

REGION = "us-west-1"
DB_NAME = "automation_calculator_app"
NAMESPACE = "ac-db-access"
FORWARDER = "deploy/db-read-proxy"
FORWARDER_PORT = 5432

# persona -> (PostgreSQL role prefix, AWS profile per environment). The role names are fixed by
# terraform/modules/aws/main_rails_app/db_read_only_access.tf and by the rds-db:connect
# statements in modules/aws/ci-iam-role and modules/aws/sso-infra-eng.
PERSONAS = {
    "infra-eng": (
        "ac_read_only_infra_eng",
        {"staging": "infra-eng-staging-ro", "production": "infra-eng-prod-ro"},
    ),
    "ci": (
        "ac_read_only_ci",
        {"staging": "ac-ci-staging-ro", "production": "ac-ci-prod-ro"},
    ),
}
ENVIRONMENTS = ("staging", "production")

CA_BUNDLE_URL = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
CA_BUNDLE_PATH = (
    pathlib.Path(__file__).resolve().parent.parent
    / "tmp"
    / "rds-ca"
    / "global-bundle.pem"
)


class Failure(Exception):
    """A problem to report in one line, without a traceback."""


def role_name(persona: str, environment: str) -> str:
    return f"{PERSONAS[persona][0]}_{environment}"


def default_profile(persona: str, environment: str) -> str:
    return PERSONAS[persona][1][environment]


def kube_context(environment: str) -> str:
    return f"ac_app_{environment}-ro"


def subnet_group_name(environment: str) -> str:
    return f"automation-calculator-db-access-subnet-group-{environment}"


def find_instance(instances: list[dict], environment: str) -> tuple[str, int]:
    """Return (endpoint address, port) of the environment's app database.

    Staging and production share an AWS account and the instance identifiers are generated, so
    the instance is recognised by its subnet group, whose name carries the environment.
    """
    wanted = subnet_group_name(environment)
    matches = [
        inst
        for inst in instances
        if inst.get("DBSubnetGroup", {}).get("DBSubnetGroupName") == wanted
        and "Endpoint" in inst
    ]
    if len(matches) != 1:
        raise Failure(
            f"expected one RDS instance in subnet group {wanted}, found {len(matches)}"
        )
    inst = matches[0]
    if not inst.get("IAMDatabaseAuthenticationEnabled"):
        raise Failure(
            f"IAM database authentication is off on the {environment} instance: "
            "db_read_only_access_enabled has not been applied there"
        )
    return inst["Endpoint"]["Address"], int(inst["Endpoint"]["Port"])


def conninfo(host: str, local_port: int, user: str, ca_bundle: pathlib.Path) -> str:
    """psql connection string: TCP to the local forward, TLS verified against the RDS name."""
    return (
        f"host={host} hostaddr=127.0.0.1 port={local_port} dbname={DB_NAME} user={user} "
        f"sslmode=verify-full sslrootcert={ca_bundle}"
    )


def port_forward_command(environment: str, local_port: int) -> list[str]:
    return [
        "kubectl",
        "--context",
        kube_context(environment),
        "--namespace",
        NAMESPACE,
        "port-forward",
        FORWARDER,
        f"{local_port}:{FORWARDER_PORT}",
    ]


def aws(profile: str, *args: str) -> str:
    cmd = ["aws", *args, "--region", REGION, "--profile", profile]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        last = (
            proc.stderr.strip().splitlines()[-1]
            if proc.stderr.strip()
            else proc.returncode
        )
        raise Failure(f"aws {args[0]} {args[1]} failed under profile {profile}: {last}")
    return proc.stdout


def ensure_ca_bundle(path: pathlib.Path = CA_BUNDLE_PATH) -> pathlib.Path:
    if not path.exists():
        logger.info("downloading the RDS certificate bundle to %s", path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(CA_BUNDLE_URL, timeout=30) as response:
            path.write_bytes(response.read())
    return path


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_forward(proc: subprocess.Popen, port: int, timeout: float = 20) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            detail = (proc.stderr.read() if proc.stderr else "").strip()
            raise Failure(
                f"kubectl port-forward exited: {detail or proc.returncode}. "
                f"Check `kubectl --namespace {NAMESPACE} get pods`: the forwarder gives up its "
                "pod slot when the node is full, and is then Pending."
            )
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.3)
    raise Failure(
        f"kubectl port-forward did not open local port {port} in {timeout:.0f} s"
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("env", choices=ENVIRONMENTS)
    ap.add_argument(
        "--as",
        dest="persona",
        choices=sorted(PERSONAS),
        required=True,
        help="which read-only role to sign in as; agents and CI use ci",
    )
    ap.add_argument(
        "--profile",
        help="AWS profile to request the token under (default: the persona's -ro profile)",
    )
    ap.add_argument(
        "--context", help="kube context for the port-forward (default: ac_app_<env>-ro)"
    )
    ap.add_argument("psql_args", nargs="*", help="arguments for psql, after --")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)

    for tool in ("aws", "kubectl", "psql"):
        if shutil.which(tool) is None:
            hint = (
                " (macOS: brew install libpq, then add its bin directory to PATH)"
                if tool == "psql"
                else ""
            )
            raise Failure(f"{tool} is not on PATH{hint}")

    profile = args.profile or default_profile(args.persona, args.env)
    user = role_name(args.persona, args.env)
    described = json.loads(
        aws(profile, "rds", "describe-db-instances", "--output", "json")
    )
    host, port = find_instance(described["DBInstances"], args.env)
    token = aws(
        profile,
        "rds",
        "generate-db-auth-token",
        "--hostname",
        host,
        "--port",
        str(port),
        "--username",
        user,
    ).strip()
    ca_bundle = ensure_ca_bundle()

    local_port = free_port()
    forward_cmd = port_forward_command(args.env, local_port)
    if args.context:
        forward_cmd[2] = args.context
    logger.info("signing in to %s as %s (profile %s)", args.env, user, profile)
    forward = subprocess.Popen(
        forward_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True
    )
    try:
        wait_for_forward(forward, local_port)
        env = dict(
            os.environ, PGPASSWORD=token, PGAPPNAME=f"db_read_only_psql/{args.persona}"
        )
        psql = subprocess.run(
            ["psql", conninfo(host, local_port, user, ca_bundle), *args.psql_args],
            env=env,
            check=False,
        )
        return psql.returncode
    finally:
        forward.terminate()
        try:
            forward.wait(timeout=5)
        except subprocess.TimeoutExpired:
            forward.kill()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
