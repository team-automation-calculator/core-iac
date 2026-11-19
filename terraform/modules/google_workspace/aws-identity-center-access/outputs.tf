output "group_email" {
  description = "Email of the Google group to turn the AWS Identity Center SAML app ON for."
  value       = googleworkspace_group.aws_identity_center.email
}

output "group_id" {
  description = "Directory ID of the Google group."
  value       = googleworkspace_group.aws_identity_center.id
}
