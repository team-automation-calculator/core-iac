"""Tests for go.py: every script in scripts/ is reachable as a ./go command."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
GO = REPO_ROOT / "go.py"

spec = importlib.util.spec_from_file_location("go", GO)
go = importlib.util.module_from_spec(spec)
spec.loader.exec_module(go)


def script_files():
    return sorted(
        path.name
        for path in (REPO_ROOT / "scripts").iterdir()
        if path.suffix in (".py", ".sh")
    )


def test_every_script_has_a_go_command():
    covered = set(go.SCRIPTS) | set(go.SCRIPTS_WITH_OWN_COMMAND)
    assert sorted(covered) == script_files()


def test_script_commands_are_registered_and_do_not_shadow_built_ins():
    names = [go.script_command_name(filename) for filename in go.SCRIPTS]
    assert len(names) == len(set(names))
    for name in names:
        assert go.COMMANDS[name] is go.SCRIPT_COMMANDS[name]
    assert len(go.COMMANDS) == len(names) + 12
    for command in go.SCRIPTS_WITH_OWN_COMMAND.values():
        assert command in go.COMMANDS


def test_script_command_name():
    assert go.script_command_name("argocd_preflight.sh") == "argocd-preflight"
    assert go.script_command_name("app_logs.py") == "app-logs"


@pytest.mark.parametrize("filename", sorted(go.SCRIPTS))
def test_every_command_has_a_one_line_summary(filename):
    summary = go.COMMANDS[go.script_command_name(filename)].__doc__
    assert summary and "\n" not in summary


def test_help_lists_the_script_commands():
    result = subprocess.run(
        [sys.executable, str(GO), "help"], capture_output=True, text=True, check=True
    )
    for filename in go.SCRIPTS:
        assert f"  {go.script_command_name(filename)} " in result.stdout


def test_script_command_passes_arguments_and_exit_status(tmp_path):
    # Runs from another directory: the script must be found by its absolute path.
    result = subprocess.run(
        [sys.executable, str(GO), "argocd-soak-log", "--help"],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        check=False,
    )
    assert result.returncode == 0
    assert "soak" in result.stdout

    result = subprocess.run(
        [sys.executable, str(GO), "argocd-soak-log", "--no-such-flag"],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        check=False,
    )
    assert result.returncode == 2


def test_post_sync_command_exists_and_matches_repo_standards():
    import tomllib

    config = tomllib.loads((REPO_ROOT / ".repo-standards.toml").read_text())
    assert config["git-sync"]["post_sync"] == f"./go {go.POST_SYNC_COMMAND}"
    assert go.POST_SYNC_COMMAND in go.COMMANDS
