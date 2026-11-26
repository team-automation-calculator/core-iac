#!/usr/bin/env python3
"""Say how far the graphify knowledge graph is behind HEAD (rule graphify).

    ./go graphify-status [--brief]
    python3 -I scripts/graphify_status.py [--brief]

Compares graph.json's built_at_commit with HEAD and splits the files changed
since into code (refreshed for free by ./go graphify-update) and documents
(Markdown, PDFs, images: they wait for the LLM pass, /graphify --update, run in
the main checkout after the merge). Files graphify does not read (YAML, lock
files) are counted apart. The split is by extension and ignores
.graphifyignore, so it can count a file the graph leaves out.

A worktree reads its own seeded copy when it has one, otherwise the main
checkout's graph. Exit status: 0 fresh, 3 stale, 1 no graph.

--brief (the SessionStart hook) prints one line only when the graph is stale,
and nothing when it is fresh or absent or in a throwaway environment
(CLAUDE_CODE_REMOTE, GITHUB_ACTIONS, CI). Standard library only, read-only.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# python3 -I leaves the script's own directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from graphify_seed import GRAPH, OUT, checkouts, ephemeral_reason

FRESH, NO_GRAPH, STALE = 0, 1, 3
DOCUMENT_EXTENSIONS = frozenset(
    {".md", ".mdx", ".txt", ".rst", ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp"}
)
# What graphify's AST pass reads, as far as this repo has any of it.
CODE_EXTENSIONS = frozenset(
    {".py", ".sh", ".bash", ".tf", ".tfvars", ".hcl", ".json", ".rb", ".js", ".ts"}
)


@dataclass
class Changes:
    code: list[str] = field(default_factory=list)
    documents: list[str] = field(default_factory=list)
    other: list[str] = field(default_factory=list)


def git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=False
    )


def graph_dir(here: Path, main_checkout: Path) -> Path | None:
    """This checkout's graph, else the main checkout's, else None."""
    for root in (here, main_checkout):
        if (root / OUT / GRAPH).is_file():
            return root / OUT
    return None


def built_at_commit(out: Path) -> str | None:
    try:
        data = json.loads((out / GRAPH).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    commit = data.get("built_at_commit") if isinstance(data, dict) else None
    return str(commit) if commit else None


def classify(paths: list[str]) -> Changes:
    changes = Changes()
    for path in paths:
        suffix = Path(path).suffix.lower()
        if suffix in DOCUMENT_EXTENSIONS:
            changes.documents.append(path)
        elif suffix in CODE_EXTENSIONS:
            changes.code.append(path)
        else:
            changes.other.append(path)
    return changes


def status(here: Path, main_checkout: Path) -> tuple[int, str]:
    """(exit status, one-line summary)."""
    out = graph_dir(here, main_checkout)
    if out is None:
        return (
            NO_GRAPH,
            f"no {OUT}/{GRAPH} (build it in the main checkout: /graphify .)",
        )
    built = built_at_commit(out)
    head = git(here, "rev-parse", "HEAD").stdout.strip()
    where = "this worktree's copy" if out.parent == here else f"{out}"
    if not built:
        return STALE, f"{where} has no built_at_commit; run ./go graphify-update"
    if head.startswith(built) or built.startswith(head):
        return FRESH, f"{where} is current at {head[:7]}"
    if git(here, "cat-file", "-e", f"{built}^{{commit}}").returncode != 0:
        return STALE, f"{where} was built from {built[:7]}, unknown here"
    behind = git(here, "rev-list", "--count", f"{built}..HEAD").stdout.strip() or "?"
    changed = git(here, "diff", "--name-only", built, "HEAD").stdout.split()
    changes = classify(changed)
    return STALE, (
        f"{where} was built at {built[:7]}, {behind} commit(s) behind HEAD "
        f"{head[:7]}: {len(changes.code)} code file(s) (./go graphify-update), "
        f"{len(changes.documents)} document(s) waiting for the LLM pass, "
        f"{len(changes.other)} other"
    )


def report(line: str) -> None:
    """The status is this command's output, not a log line: it goes to stdout,
    which a SessionStart hook adds to the session."""
    print(f"graphify: {line}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--brief",
        action="store_true",
        help="one line, only when stale (SessionStart hook)",
    )
    parser.add_argument("--cwd", type=Path, default=Path.cwd(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.brief and ephemeral_reason(dict(os.environ)):
        return FRESH
    found = checkouts(args.cwd)
    if found is None:
        if not args.brief:
            report("not a git checkout")
        return NO_GRAPH
    code, summary = status(*found)
    if not args.brief or code == STALE:
        report(summary)
    return code


if __name__ == "__main__":
    sys.exit(main())
