# CLAUDE.md

@AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Everything tool-neutral is in `AGENTS.md`, imported above; only Claude-specific guidance lives here.

The repo's claude.ai Project is `core-iac`: https://claude.ai/code/project/chan_01AbNyc2EaPGqeYqJC67yBLD (recorded in `iac/specs/claude/project.json`).

## Skills and Scripts

Claude Code skills live in `.claude/skills/<name>/SKILL.md`. **Every script a skill calls lives in the repo's `scripts/` directory, never inside the skill's own directory.** A skill is a thin set of instructions; the script is the reusable tool, and keeping it in `scripts/` lets other callers (CI, another skill, a human at a shell, a future `./go` entrypoint) run it without going through the skill. When adding or changing such a script:

- Put it at `scripts/<name>.py` or `scripts/<name>.sh`, mark it executable, and give it a docstring or header comment whose usage lines are written from the repo root (`python3 -I scripts/<name>.py ...`).
- Reference it from `SKILL.md` by its `scripts/` path, run from the repo root. Do not write `in this skill's directory`.
- Add a one-line entry to the `### Scripts` list in `AGENTS.md`, prefixed with the skill name when the script exists for that skill.
- Do not create a `.claude/skills/<name>/scripts/` directory. If one exists, moving its contents to `scripts/` is the fix (see #421 for the pattern: git rename, docstring usage lines, `SKILL.md` reference, `### Scripts` entry).
