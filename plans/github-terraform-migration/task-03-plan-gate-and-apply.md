# Task 03: plan gate, merge and apply

Human in the loop. Gates the merge of the task 02 pull request.

## Gate

The pull request starts a speculative plan in `ac_app_production_github_org`. Read it.
It must match the gate line in the pull request body: imports only, plus the alert
resources as adds if task 02 found they cannot be imported. No change, no destroy.

If the plan shows a change on a `github_repository`:

1. The attribute named is one where the configuration and GitHub disagree.
2. Change the configuration to match GitHub. Never change GitHub to match the
   configuration.
3. Push and read the new speculative plan.
4. If an attribute will not settle and it is optional and computed, leave it out of the
   module and say why in a comment.

Likely causes, most likely first: `has_projects`, `delete_branch_on_merge`, a setting
changed in the GitHub UI since the capture, `description` set to an empty string where
GitHub has none.

## Failures

| Symptom | Cause |
|---|---|
| 404 on one repository, the others read fine | That repository is not in the token's selected repositories (task 01) |
| 401 on everything | The token expired; its expiry date is in the variable description |
| 403 on `github_repository_vulnerability_alerts` | The token lacks the permission for that endpoint; see task 01 |
| "Cannot import non-existent remote object" | The import id is not the bare repository name |

## Merge and apply

1. Merge once the gate passes and CI is green.
2. The production `tf_cloud` workspace plans the `trigger_prefixes` change. Confirm it.
3. `ac_app_production_github_org` plans the import and stops at "apply pending". Read
   the plan again, since it is a new plan, then confirm.
4. Queue a fresh plan in the workspace. It must show no changes.
5. Run the capture commands from task 01 and compare with the README table.

Optional check that drift is caught: turn the wiki off on `development_vm` in the GitHub
UI, queue a plan, see one change, turn the wiki back on, queue a plan, see none.

## Rollback

- Before the apply: discard the run.
- After it: `terraform state rm 'module.repositories'`. Nothing on GitHub was changed by
  the import, so there is nothing else to undo.

## Done when

- [ ] The speculative plan matched the gate line before the merge
- [ ] The apply was confirmed and the state holds the three repositories
- [ ] A fresh plan shows no changes
