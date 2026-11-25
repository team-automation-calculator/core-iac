# Task 04: remove the import blocks and update the docs

One pull request. Depends on the task 03 apply.

## 1. Import blocks

Delete `terraform/env/production/github/org/import.tf`. The blocks are spent once the
apply has run.

## 2. `AGENTS.md`

- Repository layout: add `repository/` under `terraform/modules/github/` with a one-line
  comment, and extend the `production/github/org/` comment to say it holds repository
  settings as well as CI access.
- Add a short note, near the `GITHUB_TOKEN` paragraph:
  - repositories are protected by `archive_on_destroy` and `prevent_destroy`, so
    removing one from `repositories` fails at plan time by design
  - default branches, webhooks, deploy keys, `has_downloads` and the
    `vulnerability_alerts` argument are left unmanaged on purpose; Dependabot alerts go
    through `github_repository_vulnerability_alerts`
  - a new repository needs an entry in `repositories` and a place in the owner token's
    selected repositories

## 3. `docs/github-ci-user.md`

- Opening paragraphs: the workspace now also holds the repositories' settings.
- Section 3: the token's selected repositories are every repository in `repositories`
  (all three), not only those in `repository_permissions`. Add whatever permission task
  01 found the alerts endpoint needed, if it was more than Administration.
- Section 5: a fresh plan showing no changes now also covers repository settings.

## 4. This plan

Mark the plan done at the top of [README.md](README.md), with the pull request numbers
and the apply date.

## Done when

- [ ] `import.tf` is gone and the speculative plan shows no changes
- [ ] `AGENTS.md` and `docs/github-ci-user.md` describe what is managed
- [ ] CI is green
