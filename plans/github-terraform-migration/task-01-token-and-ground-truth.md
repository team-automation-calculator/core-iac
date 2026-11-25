# Task 01: token scope and ground truth

By hand, by an organization owner. Nothing to merge.

## 1. Add `development_vm` to the owner token

The `ac_app_production_github_org` workspace authenticates with a fine-grained owner
token held in its sensitive `GITHUB_TOKEN` environment variable
(`docs/github-ci-user.md`, section 3). It was scoped to `automation-calculator` and
`core-iac` only.

- GitHub, Settings, Developer settings, Fine-grained tokens, the token for this
  workspace.
- Repository access: add `development_vm` to the selected repositories.
- Leave the permissions as they are: Administration read and write, Metadata read,
  organization Members read and write.
- Editing the selection does not change the token value, so the Terraform Cloud
  variable needs no update. If the token has to be regenerated instead, replace the
  variable and put the new expiry date in its description.

Reading and writing the Dependabot alert setting goes through the repository
Administration permission the token already has. If the task 02 speculative plan
reports a 403 on the alerts resource, that assumption was wrong: record the permission
it needed in `docs/github-ci-user.md`.

## 2. Re-capture if time has passed

The table in [README.md](README.md) was captured on 2026-11-25. Run this again just
before task 02 and correct the table if anything moved, because a setting changed in the
GitHub UI in the meantime breaks the import-only gate. Use an account with admin on the
repositories: without it the API returns the merge settings as null.

```bash
gh api orgs/team-automation-calculator/repos --paginate --jq '.[] | {name, archived, description, homepage, visibility, default_branch, has_issues, has_wiki, has_projects, has_discussions, web_commit_signoff_required, topics}'

# Merge settings are only on the single-repository endpoint. Repeat per repository.
gh api repos/team-automation-calculator/core-iac --jq '{name, allow_squash_merge, allow_merge_commit, allow_rebase_merge, allow_auto_merge, allow_update_branch, delete_branch_on_merge, merge_commit_title, merge_commit_message, squash_merge_commit_title, squash_merge_commit_message}'

# Dependabot alerts: 204 is enabled, 404 is disabled. Repeat per repository.
gh api repos/team-automation-calculator/core-iac/vulnerability-alerts -i
```

A fourth repository in the first command's output means the plan needs a fourth entry.

## Done when

- [ ] The token's selected repositories include all three
- [ ] The README table matches a capture made the same day task 02 starts
