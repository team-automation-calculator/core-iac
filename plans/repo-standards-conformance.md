# Repo standards conformance: adopting repo-standards with CircleCI kept

Status: **proposal** (draft PR). Nothing below is implemented; this PR adds only this document. It
lays out how this repo adopts the shared standards in
[stevenuray/repo-standards](https://github.com/stevenuray/repo-standards) (Python 3.12 pinned,
Poetry, Black, Ruff, pytest, stdlib logging, a `./go` entry point, `AGENTS.md`, a recorded claude.ai
Project) while keeping CircleCI as the CI system and declaring that as an intentional exemption.

The audit was run on 2026-11-07 against this worktree with
`python3 -I ~/git/repo-standards/scripts/audit_repo.py .` (output below). The audit script needs
Python 3.11 or newer for `tomllib`; the macOS system `python3` is 3.9, so run it with the pyenv
3.12.12 interpreter. Repo facts come from reading `scripts/`, `.circleci/config.yml`, `CLAUDE.md`
and `.gitignore` on the same day; the standards facts come from `standards.md`, `audit_repo.py`,
`skill/SKILL.md` and `templates/` in the repo-standards checkout.

## Summary and recommendation

- **Adopt the standards for the Python half of the repo and leave the rest alone.** The 15 scripts
  in `scripts/` are plain-stdlib Python and are exactly what the standards are for. Terraform and
  Helm validation does not change.
- **Keep CircleCI, exempt the three CI-bound rules.** The audit only ever reads
  `.github/workflows/ci.yml` and never looks at `.circleci/`. Exempting `ci` alone is not enough:
  `compile-check` and `lint` also report "no .github/workflows/ci.yml to run it in". All three are
  exempted individually in `.repo-standards.toml` with reasons that name the CircleCI job that
  replaces them.
- **Meet the exempted rules' intent anyway.** A new CircleCI `validate_python` job runs
  `./go lint` (compile check, Black, Ruff) and `./go test` on every PR, so the checks the GitHub
  Actions template would run still gate merges.
- **Everything else is adopted as written**: `.python-version` at 3.12.12, a Poetry `pyproject.toml`
  with no runtime dependencies and a dev group of black, ruff and pytest, a first `tests/`
  directory, stderr diagnostics moved to the stdlib logger, a Python `go.py` (symlinked as `go`)
  that also wraps `terraform fmt` and `helm lint`, `AGENTS.md` holding the tool-neutral guidance
  with `CLAUDE.md` importing it, and `iac/specs/claude/project.json` recording the claude.ai
  Project.
- **Do not set `[repo] python = false`.** That would skip all six Python rules and the Python part
  of the logging rule, which is the opposite of what the scripts need.
- **Recommendation: one PR per rule, in the order below.** From PR 1 on the audit is green at every
  step, because PR 1 declares a `not yet adopted` deferral for every rule a later PR fixes, and each
  PR lifts its own deferral. Hands-on time is about 10 hours in total, spread over small reviews.
  Infrastructure risk is zero: no Terraform, Helm or cluster change rides with any step.

## Current state

The audit on 2026-11-07:

```
  overrides-file  FAIL  no .repo-standards.toml; add one naming [standards] source = 'https://github.com/stevenuray/repo-standards'
  python-version  FAIL  no .python-version (pin 3.12.12)
  poetry          FAIL  no usable pyproject.toml
  compile-check   FAIL  no .github/workflows/ci.yml to run it in
  black           FAIL  no usable pyproject.toml to declare black in
  lint            FAIL  no usable pyproject.toml to declare ruff in; no .github/workflows/ci.yml to run it in
  pytest          FAIL  no usable pyproject.toml to declare pytest in; no test_*.py files
  logging         FAIL  use Python logging: scripts/alb_alarm_window.py:190 print to sys.stderr; scripts/argo_helm_chart_versions.py:141 print to sys.stderr; scripts/argo_helm_chart_versions.py:150 print to sys.stderr; and 11 more
  ci              FAIL  no .github/workflows/ci.yml
  go-script       FAIL  no ./go script at the repo root
  claude-project  FAIL  no iac/specs/claude/project.json (templates/project/example_project.json): create the claude.ai Project 'core-iac' and record it
  routines        PASS  no claude.ai routines
  git-sync        PASS  local main is fast-forwarded from origin/main each morning and late evening by the git-sync agent
  agents-md       FAIL  no AGENTS.md: agent-neutral guidance (layout, ./go commands, conventions) goes there
  worktrees       PASS  .claude/worktrees/ is gitignored; 38 linked worktree(s), all inside the repo
  -> NONCONFORMING: 3 pass, 12 fail, 0 skipped
```

What exists today:

- **Python.** 15 scripts in `scripts/`, every one `#!/usr/bin/env python3`, argparse, standard
  library only (AWS, kubectl, gh and git are driven through `subprocess`; HTTP through
  `urllib.request`). Six use `from __future__ import annotations`. `argo_helm_chart_versions.py`
  uses `typing.Optional`, which Ruff's pyupgrade rules will rewrite. The `logging` module is not
  used anywhere. Diagnostics go to stderr with `print(..., file=sys.stderr)` in nine files:

  | Script | stderr prints |
  |---|---|
  | `infra_eng_sso.py` | 3 |
  | `pr_checklist.py` | 3 |
  | `argo_helm_chart_versions.py` | 2 |
  | `alb_alarm_window.py` | 1 |
  | `ec2_worker_node_pricing.py` | 1 |
  | `env_snapshot.py` | 1 |
  | `rds_price_list_extract.py` | 1 |
  | `tfc_workspace_inventory.py` | 1 |
  | `wait_commit_status.py` | 1 |

  Calls of the form `sys.exit("message")` also write to stderr but are not flagged by the audit
  and stay as they are. Five scripts lack the executable bit that `CLAUDE.md` requires
  (`ec2_worker_node_pricing.py`, `ec2_worker_node_utilization.py`, `rds_price_list_extract.py`,
  `rds_utilization_summary.py`, `install_tf.sh`).
- **Shell.** Nine bash scripts. The standards list `bash -n` and ShellCheck for shell as
  conventions, but the audit does not check them.
- **Tooling.** No `pyproject.toml`, `.python-version`, `poetry.lock`, tests, `go`, `AGENTS.md`,
  `iac/` or `.github/`. `.gitignore` already ignores `.claude/worktrees/` (which is why
  `worktrees` passes) and has no Python entries.
- **CI.** `.circleci/config.yml` has one `validate` workflow of 20 independent jobs: a Helm lint,
  18 `terraform fmt` plus `terraform validate` jobs (one per module and env config), and
  `validate_app_docker_image_versions`, the only Python in CI, which runs
  `python3 scripts/check_app_docker_image_versions.py --base origin/main` on `cimg/base:stable`
  with the image's stock `python3` and without `-I`.

## How the exemptions work

`.repo-standards.toml` is read by the audit. Inside `[overrides.RULE]` only `reason` is honoured; an
exempted rule prints as `SKIP` with that reason. A reason that starts with `not yet adopted` or
`partially adopted` is a deferral that `/repo-standards conform` treats as work to do; any other
wording is a permanent departure. `overrides-file` itself cannot be exempted. The file PR 1 adds:

```toml
[standards]
source = "https://github.com/stevenuray/repo-standards"

[repo]
python = true

# Permanent departures. CircleCI is this repo's CI. The audit only reads
# .github/workflows/ci.yml, so the three CI-bound rules are exempted here; their
# intent is met by the validate_python job in .circleci/config.yml.
[overrides.ci]
reason = "CircleCI (.circleci/config.yml) is this repo's CI; its validate_python job runs ./go lint and ./go test on every PR"

[overrides.compile-check]
reason = "./go compile runs inside ./go lint in the CircleCI validate_python job; the audit only reads .github/workflows/ci.yml"

[overrides.lint]
reason = "ruff check runs inside ./go lint in the CircleCI validate_python job; the audit only reads .github/workflows/ci.yml"

# Deferrals, lifted one PR at a time (plans/repo-standards-conformance.md).
[overrides.python-version]
reason = "not yet adopted: PR 2"

[overrides.poetry]
reason = "not yet adopted: PR 3"

[overrides.black]
reason = "not yet adopted: PR 4"

[overrides.pytest]
reason = "not yet adopted: PR 6"

[overrides.logging]
reason = "not yet adopted: PR 7"

[overrides.go-script]
reason = "not yet adopted: PR 8"

[overrides.agents-md]
reason = "not yet adopted: PR 10"

[overrides.claude-project]
reason = "not yet adopted: PR 11"
```

Because `lint` is permanently exempted, the audit also stops checking for the ruff dev dependency
and the `[tool.ruff]` table. PR 3 and PR 5 add them anyway, and CircleCI enforces them from PR 9 on.

## One PR per rule

Commit subjects follow the skill: `chore(standards): <what>`, with reformatting in separate `style:`
commits. Each PR lifts its own deferral in `.repo-standards.toml` and is verified by re-running the
audit. Nothing is pushed to `main` directly.

**PR 0. This document.** Time 0.5 h. Risk none. Adds `plans/repo-standards-conformance.md`. The
`plans/` line in `CLAUDE.md` already covers "investigation and migration proposals", so no edit
there.

**PR 1. `overrides-file`: link the standards and declare the exemptions.** Time 0.5 h. Risk none.
Adds the `.repo-standards.toml` above. The audit goes from 12 FAIL to 3 PASS and 12 SKIP. Commit
`chore(standards): link repo-standards and declare CircleCI exemptions`.

**PR 2. `python-version`.** Time 0.25 h. Risk none. Adds `.python-version` containing `3.12.12`.
Lifts the deferral. pyenv on the workstation already has 3.12.12 installed.

**PR 3. `poetry`.** Time 1 h. Risk none. Adds `pyproject.toml` from the standards template
(`templates/pyproject.toml`): name `core-iac`, a one-line description, `requires-python = ">=3.12"`,
`dependencies = []`, `[tool.poetry] package-mode = false`, the poetry-core build backend, a
`[dependency-groups] dev` of pytest, black and ruff at the template's constraints,
`[tool.black] target-version = ["py312"]`, `[tool.ruff] target-version = "py312"`, and
`[tool.pytest.ini_options] pythonpath = [".", "scripts"]` so tests can import the scripts as
modules. Runs `poetry lock` and commits `poetry.lock`. Adds `__pycache__/`, `.venv/`,
`.pytest_cache/` and `.ruff_cache/` to `.gitignore`. Lifts the deferral. Precondition: Poetry on the
workstation (`pipx install poetry`).

**PR 4. `black`.** Time 0.5 h. Risk none. Runs `poetry run black .` and commits the result as
`style: format scripts with Black`; expect most of the 15 scripts to change in whitespace and quote
style only. A second commit lifts the deferral. Verified by `poetry run black --check .` and the
audit. Optional: record the style commit in a `.git-blame-ignore-revs` file so `git blame` skips it.

**PR 5. Ruff clean-up (the `lint` rule stays exempted).** Time 0.5 to 1 h. Risk low. Runs
`poetry run ruff check .` and fixes what it reports. Known: `typing.Optional` in
`argo_helm_chart_versions.py` becomes `X | None` (the file already imports
`from __future__ import annotations`). Expect a few unused imports or variables elsewhere. Every
fix is reviewed for side effects rather than applied blindly, and any default rule turned off in
`[tool.ruff.lint]` carries a comment saying why. Verified by a clean `ruff check`.

**PR 6. `pytest`.** Time 1.5 h. Risk none. Adds a `tests/` directory with unit tests of the pure
functions that need no AWS, GitHub or Kubernetes access:

- `tests/test_check_app_docker_image_versions.py` for `added_versions` (the function CI already
  depends on).
- `tests/test_argo_helm_chart_versions.py` for `parse_index`, `semver_key` and `latest_stable`.
- `tests/test_external_dns_txt_prefix_migration.py` for `normalize`, `to_txt_name`, `owner_of` and
  `build_plan`.
- `tests/test_alb_alarm_window.py` for `breaches`, `replay` and `parse_time`.

Tests live only under `tests/`: the audit counts `test_*.py` anywhere in the tree, including
worktrees. Verified by `poetry run pytest`. Lifts the deferral.

**PR 7. `logging`.** Time 1.5 h. Risk low (stderr wording changes). In each of the nine scripts
above, adds a module logger (`logger = logging.getLogger(__name__)`) and a `logging.basicConfig`
call in `main()` that reads the level from `LOG_LEVEL` (default `INFO`), formats as
`%(levelname)s: %(message)s` and writes to stderr. Each `print(..., file=sys.stderr)` becomes
`logger.warning`, `logger.error` or `logger.info` according to its content. Result output on stdout
stays as `print`: the skills parse stdout from `pr_checklist.py`, `env_snapshot.py` and
`wait_commit_status.py`, and `infra_eng_sso.py up` is consumed through `eval "$(...)"`, so stdout
must not change. `sys.exit("message")` calls and the `stdout=sys.stderr` subprocess redirect in
`infra_eng_sso.py` stay as they are. Verified by the audit's `logging` line, `--help` on every
touched script, and one cheap read-only run where possible (for example `wait_commit_status.py` on
an already-merged sha). Lifts the deferral.

**PR 8. `go-script`.** Time 1.5 h. Risk none. Copies `templates/go.py` to `go.py`, marks it
executable and adds the `go` symlink. The standards say an IaC repo gets a Python `go` that calls
`terraform` and `helm`, so `REQUIRED_TOOLS` gains `terraform` and `helm` next to `poetry`. Keeps the
template commands (`init`, `test`, `compile`, `lint`, `format`, `validate`, `help`) and adds:

- `fmt`: `terraform fmt -recursive terraform/`, and `fmt-check` for the CI form.
- `helm-lint`: `helm lint helm/automation-calculator/ --strict`.
- `check-images`: `python3 -I scripts/check_app_docker_image_versions.py --base origin/main`.
- `audit`: runs `audit_repo.py` from the repo-standards checkout when it is present.

`lint` also runs `bash -n` over tracked `*.sh` files. The PR fixes the five missing executable
bits and adds the `./go` forms to the `### Terraform` and `### Helm` blocks in `CLAUDE.md` next to
the raw commands. Verified by bare `./go` (pre-flight plus usage), `./go validate`, and the audit.
Lifts the deferral.

**PR 9. CircleCI `validate_python` job (the `ci` rule stays exempted).** Time 1 h. Risk low: a
misconfigured job turns CI red and blocks merges until fixed. Adds a `validate_python` job to
`.circleci/config.yml` on a pinned `cimg/python:3.12` image (**verify** the exact tag and whether
Poetry ships in it; otherwise `pipx install poetry` in the job): checkout, `poetry install
--with dev`, `./go lint`, `./go test`. Adds the job to the `validate` workflow. Also moves
`validate_app_docker_image_versions` to the same image and `./go check-images`, keeping its
"ignore main" branch filter. Verified by a green CircleCI run on the PR. Out of scope, noted here
for a separate PR: `validate_development_aws_cluster_addons_layer` runs `terraform/validate` on
the parent env directory rather than the add-ons layer.

**PR 10. `agents-md`.** Time 1 h. Risk none. Creates `AGENTS.md` from the tool-neutral body of
`CLAUDE.md` (what the repo is, layout, apply order, commands including `./go`, the scripts list,
conventions, provider versions, the external-dns note, scratch files, pull requests, environment
variables, AWS authentication) plus the template's short "Repo standards" section pointing at
`.repo-standards.toml`. `CLAUDE.md` becomes `# CLAUDE.md`, a blank line, `@AGENTS.md`, and only the
Claude-specific remainder: the `.claude/skills/<name>/SKILL.md` rules and the "scripts live in
`scripts/`, never in a skill directory" rule. While moving, fixes two stale lines: `scripts/` is
"Python and Bash helpers", and the two `*_version_dates.json` files live under `version_dates/`.
The audit requires the `@AGENTS.md` line outside any code fence and `CLAUDE.md` to be a regular
file, not a symlink. Lifts the deferral.

**Manual 1. Create the claude.ai Project.** Projects are created only in the claude.ai UI. Create
one named `core-iac` (the name must match the last segment of the origin URL,
`team-automation-calculator/core-iac`) and copy the `chan_...` id from its URL.

**PR 11. `claude-project`.** Time 0.5 h. Risk none. Blocks on Manual 1. Adds
`iac/specs/claude/project.json` (`spec_version` 1, the id, name `core-iac`, a description,
`verified_on` set to the day it was checked, optional notes) and `iac/schemas/project.schema.json`
copied from `templates/project/project.schema.json`. Lifts the last deferral; the audit then shows
12 PASS and 3 SKIP (the three CircleCI exemptions).

### Estimate summary

| Step | Hands-on | Blocks on | Risk |
|---|---|---|---|
| PR 0 plan | 0.5 h | nothing | none |
| PR 1 overrides-file | 0.5 h | PR 0 | none |
| PR 2 python-version | 0.25 h | PR 1 | none |
| PR 3 poetry | 1 h | PR 2 | none |
| PR 4 black | 0.5 h | PR 3 | none |
| PR 5 ruff clean-up | 0.5 to 1 h | PR 3 | low |
| PR 6 pytest | 1.5 h | PR 3 | none |
| PR 7 logging | 1.5 h | PR 3 | low |
| PR 8 go-script | 1.5 h | PR 4, 5 | none |
| PR 9 CircleCI job | 1 h | PR 6, 8 | low |
| PR 10 agents-md | 1 h | PR 8 | none |
| Manual 1 claude.ai Project | 0.25 h | nothing | none |
| PR 11 claude-project | 0.5 h | Manual 1 | none |
| **Total** | **about 10 h** | **1 to 2 weeks calendar** | |

PR 4 through PR 7 are independent of each other once PR 3 is in, so they can be opened in
parallel; the order above only keeps the Black reformat ahead of the PRs that touch many lines.

## Risk register

| Risk | Where | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Black reformat makes `git blame` noisy on every script | PR 4 | certain | low | Separate `style:` commit; optional `.git-blame-ignore-revs` |
| A Ruff auto-fix removes something with a side effect | PR 5 | low | medium | Review each fix; run the PR 6 tests before merging |
| A caller depended on the exact stderr wording | PR 7 | low | low | Skills read stdout only; stdout is untouched |
| CircleCI image lacks Poetry or the tag does not exist | PR 9 | medium | low | Verify the tag; install Poetry with pipx in the job |
| A `test_*.py` lands outside `tests/` (for example in a worktree) and confuses the audit | PR 6 | low | low | Keep tests under `tests/` only |
| Upstream adds a rule (an unmerged `coverage` branch exists in repo-standards) | after PR 11 | medium | low | It appears as a new FAIL; handle as a follow-up PR |

## What stays the same

CircleCI remains the CI system and every Terraform and Helm job in it is untouched. Scripts are
still run as `python3 -I scripts/<name>.py`; the `./go` commands are additions, not replacements.
The skill files under `.claude/skills/` do not change. No runtime dependency is added: Poetry
manages dev tools only. The `plans/` and `docs/` split is unchanged.

## Open questions

- Should `./go` also wrap `terraform validate` for a named env directory? It needs `TFE_TOKEN` and
  a backend init, so the proposal leaves it out.
- `.git-blame-ignore-revs` for the Black commit: yes or no.
- Whether to pin the CircleCI Python image to the patch version (`3.12.12`) or the minor (`3.12`).

## Sources

- `~/git/repo-standards/standards.md`, `scripts/audit_repo.py` and `skill/SKILL.md` (rule ids,
  override parsing, the `conform` and `exempt` procedures).
- `~/git/repo-standards/templates/`: `pyproject.toml`, `go.py`, `AGENTS.md`, `CLAUDE.md`, `ci.yml`,
  `repo-standards.toml`, `project/example_project.json`, `project/project.schema.json`.
- The audit run of 2026-11-07 quoted above.
- This repo's `.circleci/config.yml`, `CLAUDE.md`, `.gitignore` and `scripts/`.
