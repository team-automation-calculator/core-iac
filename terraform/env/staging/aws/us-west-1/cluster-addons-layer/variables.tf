variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "argocd_admin_password_bcrypt_hash" {
  default     = null
  description = "Sensitive TFC workspace variable: bcrypt hash of the ArgoCD admin password (docs/argocd-phase-2-install.md, section 4). Never set in terraform.tfvars."
  nullable    = true
  sensitive   = true
  type        = string
}

variable "argocd_admin_password_mtime" {
  default     = null
  description = "TFC workspace variable: RFC 3339 UTC time of the last ArgoCD admin password change. Set together with argocd_admin_password_bcrypt_hash."
  nullable    = true
  type        = string
}

variable "argocd_enabled" {
  default     = false
  description = "Set to true to install ArgoCD into this environment's cluster (docs/argocd-migration-plan.md, Phase 2)."
  type        = bool
}

variable "automation_calculator_app_host" {
  description = "The host name of the automation-calculator-app"
  type        = string
}

variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "db_engine_version" {
  description = "The PostgreSQL engine version for the RDS instance."
  type        = string
}

variable "external_dns_txt_prefix" {
  default     = ""
  description = "external-dns TXT registry prefix; empty leaves it unset. Set only after pre-creating the new-format TXT records, see docs/external-dns-txt-prefix-migration.md."
  type        = string
}

variable "github_oauth_app_id" {
  description = "The GitHub OAuth App ID for the automation-calculator app."
  type        = string
}

variable "github_oauth_app_secret" {
  description = "The GitHub OAuth App Secret for the automation-calculator app."
  type        = string
}

variable "google_oauth_app_id" {
  description = "The Google OAuth App ID for the automation-calculator app."
  type        = string
}

variable "google_oauth_app_secret" {
  description = "The Google OAuth App Secret for the automation-calculator app."
  type        = string
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}

variable "tf_cloud_organization_name" {
  default     = "team-automation-calculator"
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tf_cloud_workspace_path" {
  default     = "terraform/aws/env/staging/us-west-1/cluster-addons-layer"
  description = "The path to the Terraform Cloud workspace."
  type        = string
}

variable "tfe_base_layer_workspace_name" {
  description = "The name of the Terraform Cloud workspace for the base layer."
  type        = string
}
