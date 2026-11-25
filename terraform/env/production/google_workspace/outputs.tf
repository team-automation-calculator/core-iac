output "aws_identity_center_group_email" {
  description = "Email of the Google group to turn the AWS Identity Center SAML app ON for."
  value       = module.aws_identity_center_access.group_email
}
