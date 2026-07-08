# Task 01 — Capture GitHub ground truth & verify token

**Status: mostly done (2026-07-06).** Captured values are recorded in
[README.md](README.md) "GitHub ground truth". Re-run the capture if significant time
passes before task-03 executes, since UI changes would break the zero-diff gate.

## Remaining step: verify the TFC token has admin on all repos

The workspace will authenticate with the token stored in the TFC variable set as
`TF_VAR_GITHUB_TOKEN`. Managing repo settings requires admin permission on each repo.

With that token (NOT your personal gh session):

```bash
for repo in automation-calculator core-iac development_vm; do
  curl -s -H "Authorization: Bearer $TOKEN" \
    https://api.github.com/repos/team-automation-calculator/$repo \
    | jq '{repo: .name, admin: .permissions.admin}'
done
```

All three must report `admin: true`. If not, mint a classic PAT with `repo` scope
from an org owner (stevenuray) and update the variable set.

## Re-capture commands (if needed)

```bash
for repo in automation-calculator core-iac development_vm; do
  gh api repos/team-automation-calculator/$repo --jq \
    '{name, description, homepage, visibility, has_issues, has_wiki, has_projects,
      has_downloads, has_discussions, allow_squash_merge, allow_merge_commit,
      allow_rebase_merge, allow_auto_merge, allow_update_branch,
      delete_branch_on_merge, web_commit_signoff_required, topics,
      merge_commit_title, merge_commit_message, squash_merge_commit_title,
      squash_merge_commit_message}'
  # vulnerability alerts: 204 = enabled, 404 = disabled
  gh api repos/team-automation-calculator/$repo/vulnerability-alerts \
    >/dev/null 2>&1 && echo "vulnerability_alerts: enabled" \
    || echo "vulnerability_alerts: disabled"
done
```

## Acceptance criteria

- [ ] Token in the TFC variable set confirmed admin on all 3 repos
- [ ] Captured values in README.md confirmed current (re-run if stale)
