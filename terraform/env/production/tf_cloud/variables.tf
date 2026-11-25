variable "auto_apply" {
  description = "When true, the production base cluster and cluster add-ons workspaces apply a successful plan without a confirm: merging a production pull request is the approval (docs/promotion.md). The global workspaces (Route 53 domains, GitHub organization, Google) always wait for a confirm."
  type        = bool
  default     = false
}

variable "base_cluster_layer_working_directory" {
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "cluster_addons_layer_working_directory" {
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "enable_cluster_addons_run_trigger" {
  description = "When true, creates a run trigger so that a successful apply in the base cluster workspace automatically queues a run in the cluster addons workspace."
  type        = bool
  default     = true
}

variable "enable_github_org_workspace" {
  description = "When true, creates a TFC workspace for the GitHub organization env config (CI machine user access)."
  type        = bool
  default     = false
}

variable "enable_google_cloud_workspace" {
  description = "When true, creates a TFC workspace for the Google Cloud env config (the project behind the Google service accounts)."
  type        = bool
  default     = false
}

variable "enable_google_workspace_workspace" {
  description = "When true, creates a TFC workspace for the Google Workspace env config (the group that gates the AWS Identity Center SAML app)."
  type        = bool
  default     = false
}

variable "enable_route53_domains_workspace" {
  description = "When true, creates a TFC workspace for the route53-domains env config."
  type        = bool
  default     = false
}

variable "environment_name" {
  description = "The application production environment, i.e development/staging/production."
  type        = string
}

variable "github_org_working_directory" {
  description = "The path to the GitHub organization env config directory."
  type        = string
  default     = ""
}

variable "google_cloud_working_directory" {
  description = "The path to the Google Cloud env config directory."
  type        = string
  default     = ""
}

variable "google_workspace_working_directory" {
  description = "The path to the Google Workspace env config directory."
  type        = string
  default     = ""
}

variable "route53_domains_working_directory" {
  description = "The path to the route53-domains env config directory."
  type        = string
  default     = ""
}

variable "tf_cloud_organization_name" {
  default     = "team-automation-calculator"
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  default     = "team-automation-calculator/core-iac"
  description = "The VCS repo identifier for the Terraform Cloud workspace for this layer's version control/github source"
  type        = string
}

variable "TF_VAR_GITHUB_TOKEN" {
  description = "Environment variable for the GitHub Personal Access Token to be used by Terraform Cloud to access the GitHub repository"
  type        = string
  sensitive   = true
}

variable "tfc_bootstrap_token" {
  default     = null
  description = "One-time owner-level Terraform Cloud token for the run that first creates the managed owners team token. Set it as a sensitive Terraform variable on the workspace for that run only, then delete it and revoke the token. Never set it in terraform.tfvars."
  sensitive   = true
  type        = string
}

variable "tfc_organization_members" {
  default     = {}
  description = "Terraform Cloud organization members, keyed by a short stable name. owner adds the member to the owners team. Set import_existing = true for a member who is already in the organization (and, if owner, already in the owners team) so the membership is imported instead of re-invited. Removing an entry removes the user from the organization. See docs/tfc-org-members.md."
  type = map(object({
    email           = string
    import_existing = optional(bool, false)
    owner           = optional(bool, false)
  }))
}

variable "tfc_owner_token_expired_at" {
  description = "Expiry (RFC 3339) of the owners team token this workspace runs with. Changing it rotates the token: a new one is created and stored before the old one is deleted."
  type        = string

  validation {
    condition     = can(formatdate("YYYY-MM-DD", var.tfc_owner_token_expired_at))
    error_message = "tfc_owner_token_expired_at must be an RFC 3339 timestamp, e.g. 2027-11-18T00:00:00Z."
  }
}

variable "trigger_on_shared_code" {
  default     = false
  description = "False for production: its cluster workspaces run only for changes to production's own files (the two working directories), so a shared module change applies on staging at merge and reaches production with the next production pull request (docs/promotion.md)."
  type        = bool
}

variable "tfe_workspace_tf_version" {
  description = "Allows for version pinning of tfe workspaces that have been created, because otherwise TF Cloud just chooses the latest one."
  type        = string
  default     = "1.17"
}
