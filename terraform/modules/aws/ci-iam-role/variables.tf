variable "db_read_only_access_enabled" {
  default     = false
  description = "Let the read-only CI role request IAM database tokens for the PostgreSQL role ac_read_only_ci_<environment_name> (docs/db-read-only-access.md). The role itself is created by main_rails_app when its variable of the same name is true."
  type        = bool
}

variable "environment_name" {
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "max_session_duration" {
  default     = 3600
  description = "Maximum session duration in seconds for the CI role."
  type        = number
}

variable "read_only_trusted_principal_arns" {
  default     = []
  description = "IAM principal ARNs in this account allowed to assume the read-only CI role. When empty (the default), no principal can assume the role."
  type        = list(string)
}

variable "trusted_principal_arns" {
  default     = []
  description = "IAM principal ARNs (CI users/roles) in this account allowed to assume the CI role. When empty (the default), no principal can assume the role."
  type        = list(string)
}
