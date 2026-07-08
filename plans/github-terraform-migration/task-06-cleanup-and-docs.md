# Task 06 — Cleanup import blocks + documentation updates

Delegatable to an agent. One PR (PR 4). Depends on: task-05 apply completed.

## Changes

### 1. Remove the temporary import blocks

Delete `terraform/env/global/github/import.tf`. The import blocks are one-shot;
after the apply they are dead weight. (Note: `route53-domains/import.tf` was left in
place historically — optionally remove it in this PR too; ask the user first.)

### 2. `CLAUDE.md` updates

- **Repository Layout tree**: add `terraform/modules/github/repository/` and
  `terraform/env/global/github/` with one-line comments.
- **Provider Versions table**: add row `GitHub | ~> 6.0 | ~> 6.0`.
- **Layered Apply Order**: note the global GitHub workspace
  (`ac_app_global_github`, bootstrapped from production tf_cloud, auto_apply off).
- Add a short "GitHub org management" note:
  - default branches are intentionally unmanaged (provider v6 dropped
    `default_branch` from `github_repository`)
  - webhooks/deploy keys intentionally unmanaged (CircleCI/TFC own them)
  - repos are protected by `archive_on_destroy` + `prevent_destroy`; removing one
    from tfvars errors at plan time by design
  - rotating the token in the TFC variable set now also affects GitHub plans, not
    just the VCS connection

### 3. `README.md` (optional)

Extend the TFC setup steps to mention attaching the variable set to
`ac_app_global_github`.

## Verification

- Speculative plan on this PR: "No changes."
- CI green.

## Acceptance criteria

- [ ] `import.tf` removed
- [ ] CLAUDE.md layout tree, provider table, and notes updated
- [ ] Speculative plan shows "No changes"
