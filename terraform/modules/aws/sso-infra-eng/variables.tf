variable "permission_set_name" {
  default     = "InfraEng"
  description = "Name of the IAM Identity Center permission set. Also determines the AWSReservedSSO_<name>_* role name that CI role trust policies match on."
  type        = string
}

variable "session_duration" {
  default     = "PT8H"
  description = "ISO-8601 session duration for the permission set."
  type        = string
}

variable "user_name" {
  default     = "steven.uray@automation-calculations.io"
  description = "Identity Center userName (the Google Workspace email) to assign to this account with the permission set. Empty string skips the assignment."
  type        = string
}
