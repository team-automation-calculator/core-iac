variable "group_description" {
  default     = "Members may sign in to AWS through the AWS Identity Center SAML app. Membership is managed by Terraform in core-iac; do not edit it in the Admin console."
  description = "Description shown on the Google group."
  type        = string
}

variable "group_email" {
  description = "Email address of the Google group that gates access to the AWS Identity Center SAML app."
  type        = string
}

variable "group_name" {
  default     = "AWS Identity Center access"
  description = "Display name of the Google group."
  type        = string
}

variable "member_emails" {
  description = "Primary emails of the Google Workspace users allowed to sign in to AWS. Each must also exist as an IAM Identity Center user with the same userName."
  type        = set(string)
}
