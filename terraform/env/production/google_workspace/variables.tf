variable "aws_identity_center_group_email" {
  default     = "aws-identity-center@automation-calculations.net"
  description = "Email address of the Google group that gates access to the AWS Identity Center SAML app."
  type        = string
}

variable "aws_identity_center_member_emails" {
  description = "Primary emails of the Google Workspace users allowed to sign in to AWS."
  type        = set(string)
}

variable "google_workspace_customer_id" {
  description = "Google Workspace customer ID (Admin console -> Account -> Account settings). Set as a Terraform variable on the Terraform Cloud workspace."
  type        = string
}
