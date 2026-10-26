variable "ci_github_username" {
  description = "GitHub login of the CI machine user to invite to the organization. The account itself is created by hand (docs/github-ci-user.md); GitHub has no API for creating user accounts."
  type        = string
}

variable "repository_permissions" {
  default     = {}
  description = "Repository name => permission granted to the CI team on that repository (pull, triage, push, maintain, admin)."
  type        = map(string)

  validation {
    condition     = alltrue([for p in values(var.repository_permissions) : contains(["pull", "triage", "push", "maintain", "admin"], p)])
    error_message = "Each permission must be one of: pull, triage, push, maintain, admin."
  }
}

variable "team_name" {
  default     = "ac-ci"
  description = "Name of the GitHub team that holds the CI machine user's repository permissions."
  type        = string
}
