"""Tests for scripts/graphify_update.py, graphify_status.py and graphify_seed.py.

Each test builds a throwaway git repository (and a worktree of it) under
tmp_path; graphify itself is replaced by a stub interpreter recorded in
graphify-out/.graphify_python, so nothing here needs graphify installed.
"""

import json
import logging
import os
import stat
import subprocess
from pathlib import Path

import graphify_seed
import graphify_status
import graphify_update
import pytest


def git(cwd, *args):
    return subprocess.run(
        ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True
    ).stdout.strip()


@pytest.fixture(autouse=True)
def persistent_machine(monkeypatch):
    for name in graphify_seed.EPHEMERAL_VARIABLES:
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "test@example.com")
    git(root, "config", "user.name", "Test")
    (root / "a.py").write_text("x = 1\n")
    git(root, "add", ".")
    git(root, "commit", "-q", "-m", "first")
    return root


def write_graph(root, commit):
    out = root / "graphify-out"
    out.mkdir(exist_ok=True)
    (out / "graph.json").write_text(json.dumps({"built_at_commit": commit}))
    return out


def stub_graphify(out, tmp_path, refuse_without_force=False):
    """A fake interpreter: logs its argv, and writes HEAD into graph.json."""
    log = tmp_path / "calls.log"
    refusal = (
        'case "$*" in *--force*) ;; *) echo "Refusing to overwrite" >&2; exit 0;; esac'
        if refuse_without_force
        else ""
    )
    stub = tmp_path / "python-stub"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "$*" >> "{log}"\n'
        f"{refusal}\n"
        'printf \'{"built_at_commit": "%s"}\' "$(git rev-parse HEAD)" '
        "> graphify-out/graph.json\n"
    )
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    (out / ".graphify_python").write_text(str(stub))
    return log


# graphify_update


def test_update_skips_without_a_graph(repo, caplog):
    caplog.set_level(logging.INFO)
    assert graphify_update.main(["--cwd", str(repo)]) == 0
    assert "no graphify-out/graph.json yet" in caplog.text


def test_update_skips_main_checkout_off_main(repo, tmp_path, caplog):
    caplog.set_level(logging.INFO)
    out = write_graph(repo, git(repo, "rev-parse", "HEAD"))
    log = stub_graphify(out, tmp_path)
    git(repo, "checkout", "-q", "-b", "feature")
    assert graphify_update.main(["--cwd", str(repo)]) == 0
    assert "not main" in caplog.text
    assert not log.exists()


def test_update_skips_in_ephemeral_environment(repo, tmp_path, monkeypatch):
    out = write_graph(repo, "old")
    log = stub_graphify(out, tmp_path)
    monkeypatch.setenv("CI", "true")
    assert graphify_update.main(["--cwd", str(repo)]) == 0
    assert not log.exists()


def test_update_runs_graphify_update(repo, tmp_path, monkeypatch):
    out = write_graph(repo, "old")
    log = stub_graphify(out, tmp_path)
    monkeypatch.chdir(repo)
    assert graphify_update.main(["--cwd", str(repo)]) == 0
    assert log.read_text().splitlines() == ["-m graphify update ."]
    assert graphify_update.built_at_commit(out) == git(repo, "rev-parse", "HEAD")


def test_update_retries_with_force_when_graph_shrinks(repo, tmp_path):
    out = write_graph(repo, "old")
    log = stub_graphify(out, tmp_path, refuse_without_force=True)
    assert graphify_update.main(["--cwd", str(repo)]) == 0
    assert log.read_text().splitlines() == [
        "-m graphify update .",
        "-m graphify update . --force",
    ]


def test_update_dry_run_runs_nothing(repo, tmp_path):
    out = write_graph(repo, "old")
    log = stub_graphify(out, tmp_path)
    assert graphify_update.main(["--cwd", str(repo), "--dry-run"]) == 0
    assert not log.exists()


def test_update_fails_without_graphify(repo, monkeypatch):
    write_graph(repo, "old")
    monkeypatch.setattr(graphify_seed.shutil, "which", lambda name: None)
    assert graphify_update.main(["--cwd", str(repo)]) == 1


# graphify_status


def test_status_no_graph(repo):
    assert graphify_status.main(["--cwd", str(repo)]) == graphify_status.NO_GRAPH


def test_status_fresh_is_silent_when_brief(repo, capsys):
    write_graph(repo, git(repo, "rev-parse", "HEAD"))
    assert graphify_status.main(["--cwd", str(repo), "--brief"]) == 0
    assert capsys.readouterr().out == ""


def test_status_stale_splits_code_and_documents(repo, capsys):
    write_graph(repo, git(repo, "rev-parse", "HEAD"))
    (repo / "b.tf").write_text("locals {}\n")
    (repo / "notes.md").write_text("# notes\n")
    (repo / "values.yaml").write_text("a: 1\n")
    git(repo, "add", "b.tf", "notes.md", "values.yaml")
    git(repo, "commit", "-q", "-m", "second")
    assert graphify_status.main(["--cwd", str(repo), "--brief"]) == 3
    line = capsys.readouterr().out
    assert "1 commit(s) behind" in line
    assert "1 code file(s)" in line
    assert "1 document(s)" in line
    assert "1 other" in line


def test_status_brief_silent_in_ephemeral_environment(repo, capsys, monkeypatch):
    write_graph(repo, "0000000")
    monkeypatch.setenv("CLAUDE_CODE_REMOTE", "true")
    assert graphify_status.main(["--cwd", str(repo), "--brief"]) == 0
    assert capsys.readouterr().out == ""


# graphify_seed, with graphify_update and graphify_status in the worktree


def test_seed_then_update_and_status_in_worktree(repo, tmp_path):
    out = write_graph(repo, git(repo, "rev-parse", "HEAD"))
    log = stub_graphify(out, tmp_path)
    worktree = tmp_path / "wt"
    git(repo, "worktree", "add", "-q", "-b", "feature", str(worktree))

    assert graphify_seed.main(["--cwd", str(worktree)]) == 0
    seeded = worktree / "graphify-out"
    assert (seeded / "cache" / "ast").is_symlink()
    assert (seeded / ".graphify_root").read_text() == "."
    assert log.read_text().count("update .") == 1

    (worktree / "c.py").write_text("y = 2\n")
    git(worktree, "add", "c.py")
    git(worktree, "commit", "-q", "-m", "branch work")
    assert graphify_status.main(["--cwd", str(worktree)]) == graphify_status.STALE
    assert graphify_update.main(["--cwd", str(worktree)]) == 0
    assert graphify_status.main(["--cwd", str(worktree)]) == graphify_status.FRESH
    # main's graph is untouched by the worktree's refresh.
    assert graphify_update.built_at_commit(out) != git(worktree, "rev-parse", "HEAD")


def test_scripts_are_executable():
    for name in ("graphify_update.py", "graphify_status.py", "graphify_seed.py"):
        path = Path(__file__).resolve().parent.parent / "scripts" / name
        assert os.access(path, os.X_OK), name


def test_status_brief_prints_to_stdout_through_go(repo):
    """The SessionStart hook drops stderr, so the stale line must be on stdout."""
    write_graph(repo, git(repo, "rev-parse", "HEAD"))
    (repo / "d.py").write_text("z = 3\n")
    git(repo, "add", "d.py")
    git(repo, "commit", "-q", "-m", "third")
    go = Path(__file__).resolve().parent.parent / "go"
    result = subprocess.run(
        [str(go), "graphify-status", "--brief"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
        env={
            k: v
            for k, v in os.environ.items()
            if k not in ("CI", "GITHUB_ACTIONS", "CLAUDE_CODE_REMOTE")
        },
    )
    assert result.returncode == 3
    assert result.stdout.startswith("graphify: ")
