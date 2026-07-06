data "aws_caller_identity" "current" {}

# Requires an IAM Identity Center instance to already be enabled in this
# account and region; enabling it (and connecting the external identity
# provider) is a manual console step with no AWS API.
data "aws_ssoadmin_instances" "this" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

resource "aws_ssoadmin_permission_set" "infra_eng" {
  name             = var.permission_set_name
  description      = "Infrastructure engineers: assume the per-environment CI Terraform roles"
  instance_arn     = local.instance_arn
  session_duration = var.session_duration

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_iam_policy_document" "infra_eng" {
  statement {
    sid       = "AssumeCiTerraformRoles"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ac_ci_terraform_*"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "infra_eng" {
  inline_policy      = data.aws_iam_policy_document.infra_eng.json
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.infra_eng.arn
}

# The Identity Center user is provisioned from the external identity provider
# (Google Workspace SCIM auto-provisioning, or created manually with the same
# userName), not by Terraform. Looked up here so the account assignment fails
# loudly if provisioning has not happened yet.
data "aws_identitystore_user" "infra_eng" {
  count             = var.user_name == "" ? 0 : 1
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.user_name
    }
  }
}

resource "aws_ssoadmin_account_assignment" "infra_eng" {
  count              = var.user_name == "" ? 0 : 1
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.infra_eng.arn
  principal_id       = data.aws_identitystore_user.infra_eng[0].user_id
  principal_type     = "USER"
  target_id          = data.aws_caller_identity.current.account_id
  target_type        = "AWS_ACCOUNT"
}
