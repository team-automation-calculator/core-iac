variable "application_title" {
  default     = "Automation Calculator"
  description = "The application title to use for the IAP brand"
  type        = string
}

variable "display_name" {
  default     = "Automation Calculator"
  description = "The display name to use for the IAP client"
  type        = string
}

variable "environment_name" {
  description = "The name of the environment to deploy to"
  type        = string
}

variable "google_org_id" {
  description = "The organization ID on google cloud to deploy to"
  type        = string
}

variable "project_id" {
  description = "The project ID to deploy to"
  type        = string
}

variable "redirect_uri" {
  description = "The redirect URI to use for the OAuth 2.0 client"
  type        = string
}

variable "support_email" {
  description = "The support email to use for the IAP brand"
  type        = string
}
