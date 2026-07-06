variable "environment_name" {
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "max_session_duration" {
  default     = 3600
  description = "Maximum session duration in seconds for the CI role."
  type        = number
}

variable "trusted_principal_arns" {
  default     = []
  description = "IAM principal ARNs (CI users/roles) allowed to assume the CI role. Defaults to the account root, which delegates access to any principal in the account that has sts:AssumeRole permission on this role."
  type        = list(string)
}
