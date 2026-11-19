"""Tests for scripts/bump_app_docker_image_version.sh.

The script edits files relative to its own working directory, so each test
copies it into a scratch tree shaped like the repo and runs it there.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).resolve().parent.parent
    / "scripts"
    / "bump_app_docker_image_version.sh"
)
ENVS = ("development", "staging", "production")

# The script uses BSD sed's `-i ''` and yq, so it only runs where both exist.
pytestmark = pytest.mark.skipif(
    sys.platform != "darwin" or shutil.which("yq") is None,
    reason="needs BSD sed (macOS) and yq",
)


def tfvars_path(root, env):
    return (
        root
        / "terraform"
        / "env"
        / env
        / "aws"
        / "us-west-1"
        / "cluster-addons-layer"
        / "terraform.tfvars"
    )


def make_tree(root, helm_tag, env_versions, with_app_version=ENVS):
    scripts = root / "scripts"
    scripts.mkdir()
    shutil.copy(SCRIPT, scripts / SCRIPT.name)
    values = root / "helm" / "automation-calculator" / "values.yaml"
    values.parent.mkdir(parents=True)
    values.write_text(f"image:\n  pullPolicy: Always\n  tag: {helm_tag}\n")
    for env in ENVS:
        path = tfvars_path(root, env)
        path.parent.mkdir(parents=True)
        lines = ['alarm_email                    = "someone@example.com"']
        if env in with_app_version:
            lines.append(f'app_version                    = "{env_versions[env]}"')
        lines.append('short_commit_hash              = "0000000"')
        path.write_text("\n".join(lines) + "\n")
    return scripts


def run_bump(scripts, version, commit_hash):
    return subprocess.run(
        ["bash", SCRIPT.name, version, commit_hash],
        cwd=scripts,
        capture_output=True,
        text=True,
        check=False,
    )


def test_bumps_envs_pinned_to_different_tags(tmp_path):
    # The state before #444: values.yaml and development on -980, staging and
    # production on -990. Every env must end on the new tag and hash.
    versions = {
        "development": "0.9.6-980",
        "staging": "0.9.6-990",
        "production": "0.9.6-990",
    }
    scripts = make_tree(tmp_path, "0.9.6-980", versions)

    result = run_bump(scripts, "0.9.6-996", "5beb4af")

    assert result.returncode == 0, result.stderr
    for env in ENVS:
        text = tfvars_path(tmp_path, env).read_text()
        assert 'app_version                    = "0.9.6-996"' in text
        assert 'short_commit_hash              = "5beb4af"' in text
        assert 'alarm_email                    = "someone@example.com"' in text
    values = tmp_path / "helm" / "automation-calculator" / "values.yaml"
    assert "tag: 0.9.6-996" in values.read_text()


def test_fails_when_an_env_has_no_app_version_line(tmp_path):
    versions = dict.fromkeys(ENVS, "0.9.6-990")
    scripts = make_tree(
        tmp_path,
        "0.9.6-990",
        versions,
        with_app_version=("development", "staging"),
    )

    result = run_bump(scripts, "0.9.6-996", "5beb4af")

    assert result.returncode != 0
    assert "app_version was not set" in result.stderr
    assert "production" in result.stderr
