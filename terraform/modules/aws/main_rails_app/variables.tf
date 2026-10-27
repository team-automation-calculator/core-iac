variable "automation_calculator_app_host" {
  default     = "automation-calculations.io"
  description = "The host name of the automation-calculator-app"
  type        = string
}

variable "automation_calculator_helm_release_local_path" {
  default     = "helm-charts/automation-calculator"
  description = "The local path to the helm chart for the automation-calculator app."
  type        = string
}

variable "db_engine_version" {
  default     = null
  description = "The PostgreSQL engine version for the RDS instance. If null, AWS uses its default."
  type        = string
}

variable "db_instance_class" {
  default     = "db.t4g.micro"
  description = "Amazon RDS instance type/class for the app database in this env."
  type        = string
}

variable "db_port" {
  default     = 5432
  description = "The port for the database."
  type        = number
}

variable "db_security_group_ids" {
  description = "The security group ids allowed access to the database."
  type        = list(string)
}

variable "db_subnet_group_ids" {
  description = "The ids for the subnet group to put the DB in, note this also chooses the VPC of the DB based on the subnet."
  type        = list(string)
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
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

variable "manage_helm_release" {
  default     = true
  description = "Manage the app's Helm release (helm_release.automation-calculator[0]) from Terraform. ArgoCD migration Phase 6: an env sets this to false only AFTER its workspace has run `terraform state rm` on the release, so that ArgoCD becomes the app's only controller without Terraform ever planning a destroy (prevent_destroy on the release fails the plan if the order is wrong). The namespace, Secret, RDS and ACM resources of this module are unaffected. Runbook: docs/argocd-phase-6-retire-staging-release.md."
  type        = bool
}

variable "route53_zone_name" {
  default     = "automation-calculations.io"
  description = "The name of the Route53 zone to create the DNS records in."
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID to deploy the cluster addons to."
  type        = string
}
