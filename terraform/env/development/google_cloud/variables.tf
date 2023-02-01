variable "environment_name" {
  default     = "development"
  description = "The name of the environment to deploy to"
  type        = string
}

variable "GOOGLE_ORG_ID" {
  description = "The organization ID on google cloud to deploy to, in the TF_VAR_GOOGLE_ORG_ID environment variable"
  sensitive   = true
}

variable "GOOGLE_PROJECT_ID" {
  description = "The project ID to deploy to, in the TF_VAR_GOOGLE_PROJECT_ID environment variable"
  sensitive   = true
}

variable "GOOGLE_SUPPORT_EMAIL" {
  description = "The support email to use for the IAP brand, in the TF_VAR_GOOGLE_SUPPORT_EMAIL environment variable"
  sensitive   = true
}

variable "region" {
  description = "The region to deploy to"
  default     = "us-west1"
}

variable "zone" {
  description = "The zone to deploy to"
  default     = "us-west1-b"
}
