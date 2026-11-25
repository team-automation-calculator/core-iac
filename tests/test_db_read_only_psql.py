"""Tests for scripts/db_read_only_psql.py and for the names it shares with Terraform."""

import pathlib
import re

import pytest
from db_read_only_psql import (
    Failure,
    conninfo,
    default_profile,
    find_instance,
    kube_context,
    port_forward_command,
    role_name,
)

REPO = pathlib.Path(__file__).resolve().parent.parent
MODULES = REPO / "terraform" / "modules" / "aws"


def instance(env, iam=True, address="db.example.internal"):
    return {
        "DBSubnetGroup": {
            "DBSubnetGroupName": f"automation-calculator-db-access-subnet-group-{env}"
        },
        "Endpoint": {"Address": address, "Port": 5432},
        "IAMDatabaseAuthenticationEnabled": iam,
    }


def test_role_names_carry_the_persona_and_the_environment():
    assert role_name("ci", "staging") == "ac_read_only_ci_staging"
    assert role_name("infra-eng", "production") == "ac_read_only_infra_eng_production"


def test_each_persona_uses_its_own_read_only_profile():
    assert default_profile("ci", "staging") == "ac-ci-staging-ro"
    assert default_profile("ci", "production") == "ac-ci-prod-ro"
    assert default_profile("infra-eng", "staging") == "infra-eng-staging-ro"
    assert default_profile("infra-eng", "production") == "infra-eng-prod-ro"


def test_find_instance_picks_the_environment_by_subnet_group():
    instances = [
        instance("production", address="prod.internal"),
        instance("staging", address="stg.internal"),
    ]
    assert find_instance(instances, "staging") == ("stg.internal", 5432)
    assert find_instance(instances, "production") == ("prod.internal", 5432)


def test_find_instance_fails_when_the_environment_has_no_instance():
    with pytest.raises(Failure, match="found 0"):
        find_instance([instance("production")], "staging")


def test_find_instance_fails_when_iam_authentication_is_off():
    with pytest.raises(Failure, match="IAM database authentication is off"):
        find_instance([instance("staging", iam=False)], "staging")


def test_conninfo_verifies_the_rds_name_over_the_local_forward():
    info = conninfo(
        "stg.internal", 15432, "ac_read_only_ci_staging", pathlib.Path("/ca.pem")
    )
    assert "host=stg.internal hostaddr=127.0.0.1 port=15432" in info
    assert "user=ac_read_only_ci_staging" in info
    assert "dbname=automation_calculator_app" in info
    assert "sslmode=verify-full sslrootcert=/ca.pem" in info


def test_port_forward_uses_the_read_only_context_and_the_forwarder_namespace():
    assert kube_context("staging") == "ac_app_staging-ro"
    assert port_forward_command("production", 15432) == [
        "kubectl",
        "--context",
        "ac_app_production-ro",
        "--namespace",
        "ac-db-access",
        "port-forward",
        "deploy/db-read-proxy",
        "15432:5432",
    ]


def squash(path: pathlib.Path) -> str:
    """File text with runs of spaces collapsed, so terraform fmt alignment does not matter."""
    return re.sub(r" +", " ", path.read_text())


def test_names_agree_with_terraform():
    """The role, namespace and forwarder names are written in four places; keep them in step."""
    access = squash(MODULES / "main_rails_app" / "db_read_only_access.tf")
    main = squash(MODULES / "main_rails_app" / "main.tf")
    ci = squash(MODULES / "ci-iam-role" / "main.tf")
    sso = squash(MODULES / "sso-infra-eng" / "main.tf")

    assert 'db_read_only_ci_role = "ac_read_only_ci_${var.environment_name}"' in access
    assert (
        'db_read_only_infra_eng_role = "ac_read_only_infra_eng_${var.environment_name}"'
        in access
    )
    assert ":dbuser:*/ac_read_only_ci_${var.environment_name}" in ci
    assert ":dbuser:*/ac_read_only_infra_eng_${var.environment_name}" in sso

    assert 'db_access_namespace = "ac-db-access"' in access
    assert 'db_read_proxy_name = "db-read-proxy"' in access
    assert 'db_name = "automation_calculator_app"' in main
    assert (
        '"automation-calculator-db-access-subnet-group-${var.environment_name}"' in main
    )
