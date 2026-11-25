variable "db_read_only_access_enabled" {
  default     = false
  description = "Let both InfraEng permission sets request IAM database tokens for the PostgreSQL role ac_read_only_infra_eng_<environment_name> (docs/db-read-only-access.md). The role itself is created by main_rails_app when its variable of the same name is true."
  type        = bool
}

variable "db_region" {
  default     = "us-west-1"
  description = "AWS region of the app database, for the rds-db:connect resource ARN. This module's provider targets the Identity Center region instead."
  type        = string
}

variable "environment_name" {
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "permission_set_name" {
  default     = ""
  description = "Name of the IAM Identity Center permission set. Defaults to InfraEng<EnvironmentName>. Also determines the AWSReservedSSO_<name>_* role name that CI role trust policies match on."
  type        = string
}

variable "read_only_permission_set_name" {
  default     = ""
  description = "Name of the read-only IAM Identity Center permission set. Defaults to InfraEng<EnvironmentName>ReadOnly. Also determines the AWSReservedSSO_<name>_* role name that the read-only CI role trust policy matches on."
  type        = string
}

variable "session_duration" {
  default     = "PT8H"
  description = "ISO-8601 session duration for the permission set."
  type        = string
}

variable "user_name" {
  default     = "steven.uray@automation-calculations.net"
  description = "Identity Center userName (the Google Workspace email) to assign to this account with the permission set. Empty string skips the assignment."
  type        = string
}
