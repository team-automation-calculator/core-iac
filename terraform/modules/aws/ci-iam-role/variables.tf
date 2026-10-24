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
