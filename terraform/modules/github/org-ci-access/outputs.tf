output "ci_github_username" {
  description = "GitHub login of the CI machine user."
  value       = github_membership.ci.username
}

output "team_id" {
  description = "ID of the CI team."
  value       = github_team.ci.id
}

output "team_slug" {
  description = "Slug of the CI team."
  value       = github_team.ci.slug
}
