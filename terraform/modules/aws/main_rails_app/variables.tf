variable "addons_dependency" {
  default     = []
  description = "Values the app Helm release must be installed after, e.g. the add-on Helm release names output by cluster-addons-layer. Used only for ordering via terraform_data.cluster_addons; the values are never read."
  type        = list(string)
}

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

variable "backup_retention_period" {
  default     = 0
  description = "Days to retain automated RDS backups (0 disables them, max 35). Defaults to 0, the historical behaviour; each environment sets it in tfvars. Must be non-zero before a major engine version upgrade so RDS takes its own pre- and post-upgrade snapshots. Changing between 0 and a non-zero value causes a brief outage (RDS takes the instance offline to create the first backup)."
  type        = number
}

variable "ci_read_only_kubernetes_group" {
  default     = ""
  description = "Kubernetes group the read-only CI role is mapped to by its EKS access entry. When db_read_only_access_enabled is true, the group may port-forward to the database forwarder's namespace. Empty creates no binding."
  type        = string
}

variable "db_read_only_access_enabled" {
  default     = false
  description = "Read-only database access for people and agents (docs/db-read-only-access.md): turns on IAM database authentication on the instance, runs a Job that creates the roles ac_read_only_ci_<env> and ac_read_only_infra_eng_<env> (SELECT on the app's schema, nothing else), and runs a TCP forwarder pod in the ac-db-access namespace that the read-only CI role may port-forward to. Setting it back to false removes the forwarder and turns IAM authentication off; the roles stay in the database and can no longer sign in."
  type        = bool
}

variable "db_read_only_connection_limit" {
  default     = 3
  description = "Connection limit of each read-only login role, so that observers cannot use up the instance's connections (79 on db.t4g.micro) during an incident."
  type        = number
}

variable "db_read_only_psql_image" {
  default     = "public.ecr.aws/docker/library/postgres:16.13-alpine"
  description = "Image whose psql runs the read-only roles SQL. Must carry linux/arm64. Any psql at or above the server's major version works."
  type        = string
}

variable "db_read_proxy_image" {
  default     = "public.ecr.aws/docker/library/haproxy:3.2-alpine"
  description = "Image of the TCP forwarder in front of the database. Must carry linux/arm64."
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

variable "db_snapshot_identifier" {
  default     = null
  description = "Name of an RDS snapshot to create the app database from, e.g. the final snapshot of a destroyed environment. Read only when the instance is created: changes on an existing instance are ignored, so setting or editing it never replaces a live database. Null creates an empty database."
  type        = string
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

variable "final_snapshot_identifier" {
  default     = null
  description = "Name of the final DB snapshot taken when the RDS instance is destroyed; only used when skip_final_snapshot is false. If null, automation-calculator-<environment_name>-final is used. Must start with a letter, contain only letters, numbers and hyphens, and not end with a hyphen or contain two consecutive hyphens. A destroy fails if a snapshot with this name already exists."
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

variable "skip_final_snapshot" {
  default     = true
  description = "Whether to skip the final DB snapshot when the RDS instance is destroyed. Defaults to true (the historical behaviour); set to false to take a final snapshot named by final_snapshot_identifier."
  type        = bool
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
