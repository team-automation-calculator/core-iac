output "ci_team_slug" {
  description = "Slug of the GitHub team that holds the CI machine user's repository permissions."
  value       = module.org_ci_access.team_slug
}
