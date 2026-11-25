data "aws_caller_identity" "current" {}

# Requires an IAM Identity Center instance to already exist, and the AWS
# provider passed to this module must target the instance's primary region
# (us-east-1 for this organization) — ssoadmin/identitystore APIs only
# respond there. Connecting the external identity provider is a manual
# console step with no AWS API (sso-admin has no operation for the identity
# source, the IdP metadata or SCIM), so the expected values of that link are
# recorded in iac/specs/sso/google-workspace-saml.json.
data "aws_ssoadmin_instances" "this" {}

# The Google Workspace SAML app is configured by hand for one specific
# Identity Center instance: its Entity ID carries the identity store id and
# the access portal URL carries the instance id. If the instance is ever
# deleted and re-enabled, both ids change, every sign-in fails, and nothing
# else in a plan would say why.
#
# The repo is public, so the ids are not committed. Instead the first apply
# records the live ids in state, and ignore_changes keeps that record as it
# was, so a later plan can compare the live instance against it. After an
# intended change of instance (and the matching edits in Google Admin),
# re-record with: terraform apply -replace=<address of this resource>
resource "terraform_data" "identity_center_pin" {
  input = sensitive({
    identity_store_id = local.identity_store_id
    instance_arn      = local.instance_arn
  })

  lifecycle {
    ignore_changes = [input]
  }
}

# A check only warns; it never blocks an apply.
check "identity_center_instance_matches_pin" {
  assert {
    condition     = nonsensitive(terraform_data.identity_center_pin.output.instance_arn == local.instance_arn)
    error_message = "The IAM Identity Center instance is no longer the one recorded when this module was first applied. The Google Workspace SAML app and ~/.aws/config still point at the old instance: update the app's ACS URL and Entity ID in Google Admin (iac/specs/sso/google-workspace-saml.json lists the settings), then re-record with terraform apply -replace on terraform_data.identity_center_pin."
  }

  assert {
    condition     = nonsensitive(terraform_data.identity_center_pin.output.identity_store_id == local.identity_store_id)
    error_message = "The IAM Identity Center identity store is no longer the one recorded when this module was first applied. The Google Workspace SAML app's Entity ID carries the old id: update it in Google Admin, then re-record with terraform apply -replace on terraform_data.identity_center_pin."
  }
}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  permission_set_name = (
    var.permission_set_name != ""
    ? var.permission_set_name
    : "InfraEng${title(var.environment_name)}"
  )

  read_only_permission_set_name = (
    var.read_only_permission_set_name != ""
    ? var.read_only_permission_set_name
    : "InfraEng${title(var.environment_name)}ReadOnly"
  )

  # Direct read-only access for both InfraEng personas, mirroring the
  # ReadInfrastructureServices statement of the CI read-only role
  # (modules/aws/ci-iam-role): enough to list EKS clusters, read CloudWatch
  # logs and metrics, and inspect resources from the console or CLI without
  # first assuming the CI role. Kept verb-uniform per service to stay easy
  # to diff against the CI role's lists.
  read_only_infrastructure_actions = [
    "acm:Describe*",
    "acm:Get*",
    "acm:List*",
    "autoscaling:Describe*",
    "autoscaling:Get*",
    "autoscaling:List*",
    "cloudwatch:Describe*",
    "cloudwatch:Get*",
    "cloudwatch:List*",
    "ec2:Describe*",
    "ec2:Get*",
    "ec2:List*",
    "eks:Describe*",
    "eks:Get*",
    "eks:List*",
    "elasticloadbalancing:Describe*",
    "elasticloadbalancing:Get*",
    "elasticloadbalancing:List*",
    "kms:Describe*",
    "kms:Get*",
    "kms:List*",
    "logs:Describe*",
    "logs:Get*",
    "logs:List*",
    "rds:Describe*",
    "rds:Get*",
    "rds:List*",
    "route53:Get*",
    "route53:List*",
    "route53domains:Get*",
    "route53domains:List*",
    "sns:Get*",
    "sns:List*",
  ]

  # Searching CloudWatch Logs, for both InfraEng personas: the same three
  # actions as the SearchLogs statement of the CI read-only role
  # (modules/aws/ci-iam-role), so the engineer's own SSO session can search
  # the app log group without first assuming that role. The verb patterns
  # above do not match them (plans/app-log-persistence.md).
  search_logs_actions = [
    "logs:FilterLogEvents",
    "logs:StartQuery",
    "logs:StopQuery",
  ]
}

resource "aws_ssoadmin_permission_set" "infra_eng" {
  name             = local.permission_set_name
  description      = "Infrastructure engineers: assume the ${var.environment_name} CI Terraform role, plus direct read-only infrastructure access"
  instance_arn     = local.instance_arn
  session_duration = var.session_duration

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_iam_policy_document" "infra_eng" {
  statement {
    sid       = "AssumeCiTerraformRole"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ac_ci_terraform_${var.environment_name}"]
  }

  statement {
    sid       = "ReadInfrastructureServices"
    actions   = local.read_only_infrastructure_actions
    resources = ["*"]
  }

  statement {
    sid       = "SearchLogs"
    actions   = local.search_logs_actions
    resources = ["*"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "infra_eng" {
  inline_policy      = data.aws_iam_policy_document.infra_eng.json
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.infra_eng.arn
}

# Read-only variant: same shape as InfraEng<Env>, but its inline policy only
# allows assuming the read-only CI role, for plans and inspection without
# write access.
resource "aws_ssoadmin_permission_set" "infra_eng_read_only" {
  name             = local.read_only_permission_set_name
  description      = "Infrastructure engineers (read-only): assume the ${var.environment_name} read-only CI Terraform role, plus direct read-only infrastructure access"
  instance_arn     = local.instance_arn
  session_duration = var.session_duration

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_iam_policy_document" "infra_eng_read_only" {
  statement {
    sid       = "AssumeCiTerraformReadOnlyRole"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ac_ci_terraform_${var.environment_name}_read_only"]
  }

  statement {
    sid       = "ReadInfrastructureServices"
    actions   = local.read_only_infrastructure_actions
    resources = ["*"]
  }

  statement {
    sid       = "SearchLogs"
    actions   = local.search_logs_actions
    resources = ["*"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "infra_eng_read_only" {
  inline_policy      = data.aws_iam_policy_document.infra_eng_read_only.json
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.infra_eng_read_only.arn
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

# The same engineer gets both permission sets and picks the read-only or
# read-write persona at sign-in.
resource "aws_ssoadmin_account_assignment" "infra_eng_read_only" {
  count              = var.user_name == "" ? 0 : 1
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.infra_eng_read_only.arn
  principal_id       = data.aws_identitystore_user.infra_eng[0].user_id
  principal_type     = "USER"
  target_id          = data.aws_caller_identity.current.account_id
  target_type        = "AWS_ACCOUNT"
}
