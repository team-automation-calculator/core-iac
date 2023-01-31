variable "GOOGLE_PROJECT_ID" {
  description = "The project ID to deploy to, in the TF_VAR_GOOGLE_PROJECT_ID environment variable"
}

variable "region" {
  description = "The region to deploy to"
  default     = "us-west1"
}

variable "zone" {
  description = "The zone to deploy to"
  default     = "us-west1-b"
}