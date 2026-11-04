variable "ci_github_username" {
  description = "GitHub login of the CI machine user to invite to the organization."
  type        = string
}

variable "github_organization" {
  default     = "team-automation-calculator"
  description = "GitHub organization that owns the repositories and the CI team."
  type        = string
}

variable "repository_permissions" {
  default     = {}
  description = "Repository name => permission granted to the CI team on that repository (pull, triage, push, maintain, admin)."
  type        = map(string)
}
