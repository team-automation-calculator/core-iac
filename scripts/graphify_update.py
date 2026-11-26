#!/usr/bin/env python3
"""Refresh the graphify knowledge graph's code layer, with no LLM call (rule graphify).

    ./go graphify-update [--dry-run]
    python3 -I scripts/graphify_update.py [--dry-run]

In the main checkout it refreshes main's graph (graphify-out/, gitignored) and
does nothing unless main is checked out: the graph is main's, never a feature
branch's. In a worktree seeded by ./go graphify-seed it refreshes that
worktree's private copy. It runs `<python> -m graphify update .` through the
interpreter recorded in graphify-out/.graphify_python, because the git-sync
agent's PATH (launchd's) finds no pyenv or pipx shim.

When graphify refuses a rebuild with fewer nodes than before (after a PR that
deleted or moved code), it runs again with --force: a graph that shrank with
the code it describes is correct.

Exits 0 with nothing done when there is no graph yet, when the main checkout is
on another branch, and in a throwaway environment (CLAUDE_CODE_REMOTE,
GITHUB_ACTIONS, CI). Exits 1 when graphify is missing or the update fails, so
the git-sync agent reports the repo. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

# python3 -I leaves the script's own directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from graphify_seed import (
    GRAPH,
    OUT,
    UPDATE_TIMEOUT_SECONDS,
    checkouts,
    ephemeral_reason,
    update_command,
)

LOG = logging.getLogger("graphify-update")
MAIN_BRANCH = "main"
SHRINK_REFUSAL = "Refusing to overwrite"


def current_branch(cwd: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def built_at_commit(out: Path) -> str | None:
    try:
        data = json.loads((out / GRAPH).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    commit = data.get("built_at_commit") if isinstance(data, dict) else None
    return str(commit) if commit else None


def skip_reason(here: Path, main_checkout: Path) -> str | None:
    """Why this checkout's graph is not refreshed, or None when it is."""
    if here == main_checkout:
        branch = current_branch(here)
        if branch != MAIN_BRANCH:
            return (
                f"the main checkout is on {branch or 'a detached HEAD'}, not "
                f"{MAIN_BRANCH}; the graph is {MAIN_BRANCH}'s"
            )
        if not (here / OUT / GRAPH).is_file():
            return f"no {OUT}/{GRAPH} yet (build it here once: /graphify .)"
    elif not (here / OUT / GRAPH).is_file():
        return f"no {OUT}/{GRAPH} in this worktree (seed it: ./go graphify-seed)"
    return None


def run_update(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
        timeout=UPDATE_TIMEOUT_SECONDS,
    )


def refresh(command: list[str], cwd: Path) -> bool:
    """Run the update, again with --force if graphify refused a smaller graph."""
    result = run_update(command, cwd)
    if SHRINK_REFUSAL in result.stdout + result.stderr:
        LOG.info("the rebuild has fewer nodes (code was removed); running with --force")
        result = run_update([*command, "--force"], cwd)
    if result.returncode != 0 or SHRINK_REFUSAL in result.stdout + result.stderr:
        LOG.error(
            "graphify update failed:\n%s", (result.stderr or result.stdout).strip()
        )
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--dry-run", action="store_true", help="say what would run, run nothing"
    )
    parser.add_argument("--cwd", type=Path, default=Path.cwd(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="graphify-update: %(message)s")

    reason = ephemeral_reason(dict(os.environ))
    if reason:
        LOG.info("skipping: %s", reason)
        return 0
    found = checkouts(args.cwd)
    if found is None:
        LOG.info("skipping: not a git checkout")
        return 0
    here, main_checkout = found
    reason = skip_reason(here, main_checkout)
    if reason:
        LOG.info("skipping: %s", reason)
        return 0
    out = here / OUT
    command = update_command(out)
    if command is None:
        LOG.error("graphify not found: no %s/.graphify_python and none on PATH", OUT)
        return 1
    before = built_at_commit(out)
    if args.dry_run:
        LOG.info("would run in %s: %s", here, " ".join(command))
        return 0
    try:
        if not refresh(command, here):
            return 1
    except subprocess.TimeoutExpired:
        LOG.error("graphify update timed out after %ds", UPDATE_TIMEOUT_SECONDS)
        return 1
    after = built_at_commit(out)
    LOG.info(
        "code layer refreshed (no LLM): built_at_commit %s -> %s",
        (before or "?")[:7],
        (after or "?")[:7],
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
