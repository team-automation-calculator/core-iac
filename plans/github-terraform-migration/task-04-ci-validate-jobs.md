# Task 04 — CircleCI validate jobs for the new Terraform directories

Delegatable to an agent. Ships in the same PR as task-03 (PR 3).

## Context

`.circleci/config.yml` uses the `circleci/terraform@3.1` orb with hardcoded
per-directory jobs: each terraform dir gets a job running `terraform/fmt` then
`terraform/validate` with `path: <dir>`, plus an entry under
`workflows.validate.jobs`. There is no dynamic discovery.

Known gap: `terraform/modules/aws/ci-iam-role` (added in commit dc1d3be) has **no**
validate job — fix it here since we're already editing the file, and call it out in
the PR description.

## Changes to `.circleci/config.yml`

Copy the shape of an existing module-validate job (e.g. the route53-domain or
tf_cloud_workspaces one) for three new jobs:

1. `validate_github_repository_module` — `path: terraform/modules/github/repository`
2. `validate_global_github_env` — `path: terraform/env/global/github`
3. `validate_ci_iam_role_module` — `path: terraform/modules/aws/ci-iam-role`
   (the pre-existing gap)

Add all three to the `workflows.validate.jobs` list, keeping whatever ordering
convention the file uses (module jobs grouped with module jobs, env jobs with env
jobs).

Note: the env-config job validates a dir with a `backend "remote"` block and no TFC
credentials. Check how existing env-config validate jobs handle this (they validate
fine because the orb's validate step initializes with `-backend=false` or
equivalent); mirror exactly what the existing env jobs do.

## Acceptance criteria

- [ ] Three new jobs defined and wired into `workflows.validate.jobs`
- [ ] CI green on the PR, including all pre-existing jobs
- [ ] PR description mentions the ci-iam-role gap fix
