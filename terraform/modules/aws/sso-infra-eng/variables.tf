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
