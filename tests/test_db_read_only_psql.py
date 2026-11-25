"""Tests for scripts/db_read_only_psql.py and for the names it shares with Terraform."""

import pathlib
import re

import pytest
from db_read_only_psql import (
    PSQL_IMAGE,
    Failure,
    choose_psql,
    conninfo,
    default_profile,
    docker_psql_command,
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


def test_psql_choice_prefers_local_and_falls_back_to_docker():
    assert choose_psql("auto", have_psql=True, have_docker=True) == "local"
    assert choose_psql("auto", have_psql=False, have_docker=True) == "docker"
    assert choose_psql("docker", have_psql=True, have_docker=True) == "docker"
    assert choose_psql("local", have_psql=True, have_docker=False) == "local"


def test_psql_choice_fails_when_the_chosen_client_is_missing():
    with pytest.raises(Failure, match="neither psql nor docker"):
        choose_psql("auto", have_psql=False, have_docker=False)
    with pytest.raises(Failure, match="psql is not on PATH"):
        choose_psql("local", have_psql=False, have_docker=True)
    with pytest.raises(Failure, match="docker is not on PATH"):
        choose_psql("docker", have_psql=True, have_docker=False)


def docker_command(tmp_path, platform="darwin", tty=False, args=("-c", "select 1")):
    ca = tmp_path / "rds-ca" / "global-bundle.pem"
    return docker_psql_command(
        "stg.internal",
        15432,
        "ac_read_only_ci_staging",
        ca,
        list(args),
        cwd=tmp_path,
        tty=tty,
        platform=platform,
    )


def test_docker_psql_maps_the_rds_name_to_the_host_and_verifies_it(tmp_path):
    cmd = docker_command(tmp_path)
    assert cmd[:4] == ["docker", "run", "--rm", "--interactive"]
    assert "--tty" not in cmd
    assert cmd[cmd.index("--add-host") + 1] == "stg.internal:host-gateway"
    assert f"{tmp_path / 'rds-ca'}:/rds-ca:ro" in cmd
    image = cmd.index(PSQL_IMAGE)
    assert cmd[image + 1] == "psql"
    info = cmd[image + 2]
    assert "host=stg.internal port=15432" in info
    assert "hostaddr" not in info
    assert "sslmode=verify-full sslrootcert=/rds-ca/global-bundle.pem" in info
    assert cmd[image + 3 :] == ["-c", "select 1"]


def test_docker_psql_takes_the_token_from_the_environment_not_the_arguments(tmp_path):
    cmd = docker_command(tmp_path)
    assert [cmd[i + 1] for i, part in enumerate(cmd) if part == "--env"] == [
        "PGPASSWORD",
        "PGAPPNAME",
    ]
    assert not any("PGPASSWORD=" in part for part in cmd)


def test_docker_psql_shares_only_tmp_of_the_working_directory(tmp_path):
    assert not any(part.endswith(":/work/tmp") for part in docker_command(tmp_path))
    (tmp_path / "tmp").mkdir()
    cmd = docker_command(tmp_path, tty=True)
    assert f"{tmp_path / 'tmp'}:/work/tmp" in cmd
    assert cmd[cmd.index("--workdir") + 1] == "/work"
    assert "--tty" in cmd


def test_docker_psql_on_linux_uses_the_host_network_and_loopback(tmp_path):
    cmd = docker_command(tmp_path, platform="linux")
    assert cmd[cmd.index("--network") + 1] == "host"
    assert "--add-host" not in cmd
    assert "host=stg.internal hostaddr=127.0.0.1 port=15432" in cmd[-3]


def test_psql_image_is_the_official_postgres_image_on_a_fixed_major():
    assert re.fullmatch(r"postgres:\d+-alpine", PSQL_IMAGE)


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
