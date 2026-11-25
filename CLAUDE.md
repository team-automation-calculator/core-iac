# CLAUDE.md

@AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Everything tool-neutral is in `AGENTS.md`, imported above; only Claude-specific guidance lives here.

The repo's claude.ai Project is `core-iac`: https://claude.ai/code/project/chan_01AbNyc2EaPGqeYqJC67yBLD (recorded in `iac/specs/claude/project.json`).

## Session Start: the Knowledge Graph

The SessionStart hook in `.claude/settings.json` runs two commands, one after the other (hooks in one group run in parallel, so they share one command):

- `./go graphify-seed --quiet`: in a worktree with no `graphify-out/`, copies the main checkout's graph and refreshes its code layer to the branch (no LLM). Silent and a no-op in the main checkout, in a worktree already seeded, when the main checkout has no graph yet, and in a cloud or CI session.
- `./go graphify-status --brief`: when the graph is behind `HEAD`, the session opens with one `graphify:` line saying how far. Follow it: `./go graphify-update` before relying on the graph ("Knowledge Graph" in `AGENTS.md`). It prints nothing when the graph is current or absent.

The `/graphify` skill looks for `graphify-out/graph.json` in the current directory; never run `/graphify .` in a worktree, which would build a graph of the branch.

## Skills and Scripts

Claude Code skills live in `.claude/skills/<name>/SKILL.md`. **Every script a skill calls lives in the repo's `scripts/` directory, never inside the skill's own directory.** A skill is a thin set of instructions; the script is the reusable tool, and keeping it in `scripts/` lets other callers (CI, another skill, a human at a shell, `./go`) run it without going through the skill. When adding or changing such a script:

- Put it at `scripts/<name>.py` or `scripts/<name>.sh`, mark it executable, and give it a docstring or header comment whose usage lines are written from the repo root (`python3 -I scripts/<name>.py ...`).
- Add it to `SCRIPTS` in `go.py` with a one-line summary, which makes it `./go <name-with-dashes>` (`tests/test_go.py` fails without the entry).
- Reference it from `SKILL.md` by its `./go` command, naming the `scripts/` path once where the script is introduced. Do not write `in this skill's directory`.
- Add a one-line entry for the `./go` command to the `### Scripts` list in `AGENTS.md`, prefixed with the skill name when the script exists for that skill.
- Do not create a `.claude/skills/<name>/scripts/` directory. If one exists, moving its contents to `scripts/` is the fix (see #421 for the pattern: git rename, docstring usage lines, `SKILL.md` reference, `### Scripts` entry).
