variable "max_session_duration" {
  default     = 3600
  description = "Maximum session duration in seconds for the infra_eng role."
  type        = number
}

variable "require_mfa" {
  default     = false
  description = "Require an MFA-authenticated session to assume the infra_eng role."
  type        = bool
}

variable "user_name" {
  default     = "suray"
  description = "Name of the IAM user allowed to assume the infra_eng role."
  type        = string
}
