variable "enabled_apis" {
  description = "Google Cloud APIs to keep enabled on the project. Removing one stops managing it; it is not disabled."
  type        = set(string)
}

variable "google_cloud_folder_id" {
  default     = null
  description = "Numeric ID of the folder the project sits in. Leave unset when the project sits directly under the organization. Set as a Terraform variable on the Terraform Cloud workspace."
  type        = string
}

variable "google_cloud_organization_domain" {
  default     = "automation-calculations.net"
  description = "Primary domain of the Google Workspace account that owns the Google Cloud organization."
  type        = string
}

variable "google_cloud_project_id" {
  description = "ID of the existing Google Cloud project to import and manage. Set as a Terraform variable on the Terraform Cloud workspace."
  type        = string
}

variable "google_cloud_project_name" {
  description = "Display name of the project, exactly as it is today, so the import plans no rename. Set as a Terraform variable on the Terraform Cloud workspace."
  type        = string
}

variable "labels" {
  default     = {}
  description = "Labels on the project. Authoritative: a label added in the console is removed on the next apply."
  type        = map(string)
}

variable "organization_iam_members" {
  default     = []
  description = "Organization-level IAM grants to keep in place. Additive: grants not listed are left alone. The workspace's service account needs Organization Administrator before this can be non-empty; see docs/google-cloud-terraform.md."
  type = set(object({
    member = string
    role   = string
  }))
}

variable "service_accounts" {
  default     = {}
  description = "Service accounts in the project, keyed by account ID (the part of the email before the @). project_roles are granted on this project, additively. Set import_existing = true for an account that was made by hand, so it and its listed roles are imported instead of created."
  type = map(object({
    description     = optional(string)
    display_name    = optional(string)
    import_existing = optional(bool, false)
    project_roles   = optional(set(string), [])
  }))
}
