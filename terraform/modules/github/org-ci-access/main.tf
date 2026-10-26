# Invites the CI machine user to the organization. This creates a pending
# invitation; the machine user accepts it once by hand (docs/github-ci-user.md).
# The CI user is always a plain member, never an owner.
resource "github_membership" "ci" {
  username = var.ci_github_username
  role     = "member"
}

# Repository permissions are granted through a team rather than per-repository
# collaborator entries so they have one home and survive tightening the
# organization's default repository permission.
resource "github_team" "ci" {
  name        = var.team_name
  description = "CI machine users (automation_calculator)"
  privacy     = "closed"
}

resource "github_team_membership" "ci" {
  team_id  = github_team.ci.id
  username = github_membership.ci.username
  role     = "member"
}

resource "github_team_repository" "ci" {
  for_each   = var.repository_permissions
  team_id    = github_team.ci.id
  repository = each.key
  permission = each.value
}
