module "aws_identity_center_access" {
  group_email   = var.aws_identity_center_group_email
  member_emails = var.aws_identity_center_member_emails
  source        = "../../../modules/google_workspace/aws-identity-center-access"
}
