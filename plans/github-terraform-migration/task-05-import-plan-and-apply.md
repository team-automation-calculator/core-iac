# Task 05 — Speculative-plan gate, merge, and manual import apply

Human-in-the-loop task (TFC console + PR review). Gates the merge of PR 3
(task-03 + task-04).

## Gate: speculative plan on PR 3

Opening/updating PR 3 triggers a speculative plan in `ac_app_global_github`
(VCS-connected workspace). The plan MUST read exactly:

```
Plan: 3 to import, 0 to add, 0 to change, 0 to destroy.
```

If it shows changes:

1. Read the diff per attribute — each mismatch means the config value doesn't match
   GitHub's actual state.
2. Fix `terraform.tfvars` / module defaults to match reality (do NOT change GitHub
   to match the config — fidelity is as-is).
3. Push the fix; re-check the new speculative plan.
4. If an attribute won't converge (provider quirk), consider omitting it if it is
   Optional+Computed, and document the exclusion in the module.

Common suspects if drift appears: `vulnerability_alerts`, `has_projects`,
`has_downloads`, `security_and_analysis` (should be omitted), merge-commit
title/message settings.

## Failure modes

- **401/403 in plan**: variable set not attached to the workspace, or token lacks
  admin — revisit task-02 step 2 / task-01 verification.
- **"workspace not found" on backend**: backend block name doesn't match the actual
  TFC workspace name — compare with TFC console (route53 rename precedent).
- **Import errors ("resource does not exist")**: import `id` must be the bare repo
  name (provider owner supplies the org).

## Merge + apply

1. Merge PR 3 once the gate passes and CI is green.
2. The merge triggers a plan in `ac_app_global_github`; `auto_apply` is false —
   **manually confirm the apply** in the TFC console.
3. Post-apply verification: queue a fresh plan → must say
   "No changes. Your infrastructure matches the configuration."
4. Optional smoke test: toggle `has_wiki` on one repo in the GitHub UI, queue a
   plan, confirm Terraform reports 1 change, revert the toggle in the UI, re-plan
   to zero.

## Rollback

- Pre-apply: discard the run.
- Post-apply: `terraform state rm 'module.github_repositories'` (works on VCS
  workspaces with TFE_TOKEN set locally) — imports made no GitHub-side changes.

## Acceptance criteria

- [ ] Speculative plan showed exactly 3 imports, 0 changes before merge
- [ ] Apply confirmed; state contains the 3 repositories
- [ ] Fresh post-apply plan shows "No changes"
