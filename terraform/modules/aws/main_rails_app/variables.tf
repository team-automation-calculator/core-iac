variable "app_image_pull_policy" {
  default     = "Always"
  description = "The image pull policy for the automation-calculator app."
  type        = string
}

variable "app_image_repo" {
  default     = "automationcalculationsci/automation-calculator"
  description = "The name of the docker image repo to pull the automation-calculator app image from."
  type        = string
}

variable "app_version" {
  description = "The version of the automation-calculator app to deploy."
  type        = string
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
  default     = 7
  description = "Days to retain automated RDS backups (0 disables them, max 35). Must be non-zero before a major engine version upgrade so RDS takes its own pre- and post-upgrade snapshots. Changing between 0 and a non-zero value causes a brief outage (RDS takes the instance offline to create the first backup)."
  type        = number
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

variable "short_commit_hash" {
  default     = ""
  description = "The short git commit hash of the automation-calculator app version being deployed. Sourced from the image's org.opencontainers.image.revision label at bump time."
  type        = string
}

variable "skip_final_snapshot" {
  default     = true
  description = "Whether to skip the final DB snapshot when the RDS instance is destroyed. Defaults to true (the historical behaviour); set to false to take a final snapshot named by final_snapshot_identifier."
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
