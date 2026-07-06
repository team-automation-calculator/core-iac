data "aws_caller_identity" "current" {}

locals {
  role_name = "ac_infra_eng"
}

# Human bootstrap identity. No access keys are managed by Terraform (so no
# long-lived secrets land in state); the user creates their own key out of
# band, and that key's only power is assuming the infra_eng role — all real
# work happens on the short-lived STS tokens the role chain returns.
resource "aws_iam_user" "infra_eng" {
  name = var.user_name

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_iam_policy_document" "assume_infra_eng" {
  statement {
    sid       = "AllowAssumingInfraEngRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.infra_eng.arn]
  }
}

resource "aws_iam_policy" "assume_infra_eng" {
  name        = "ac_assume_infra_eng"
  description = "Allows assuming the ${local.role_name} role. The only permission human bootstrap identities carry."
  policy      = data.aws_iam_policy_document.assume_infra_eng.json

  tags = {
    Project = "automation_calculator"
  }
}

resource "aws_iam_user_policy_attachment" "assume_infra_eng" {
  user       = aws_iam_user.infra_eng.name
  policy_arn = aws_iam_policy.assume_infra_eng.arn
}

data "aws_iam_policy_document" "infra_eng_assume_role" {
  statement {
    sid     = "AllowInfraEngineersToAssume"
    actions = ["sts:AssumeRole"]

    # Same pattern as the ci-iam-role module: the account root principal only
    # scopes trust to this account, and the aws:PrincipalArn condition
    # restricts assumption to the explicit allowlist.
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_user.infra_eng.arn]
    }

    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []
      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "infra_eng" {
  name                 = local.role_name
  description          = "Assumed by infrastructure engineers to reach the per-environment CI Terraform roles"
  assume_role_policy   = data.aws_iam_policy_document.infra_eng_assume_role.json
  max_session_duration = var.max_session_duration

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_iam_policy_document" "infra_eng_permissions" {
  statement {
    sid       = "AssumeCiTerraformRoles"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ac_ci_terraform_*"]
  }
}

resource "aws_iam_policy" "infra_eng" {
  name        = local.role_name
  description = "Permissions for infrastructure engineers: assume the per-environment CI Terraform roles"
  policy      = data.aws_iam_policy_document.infra_eng_permissions.json

  tags = {
    Project = "automation_calculator"
  }
}

resource "aws_iam_role_policy_attachment" "infra_eng" {
  role       = aws_iam_role.infra_eng.name
  policy_arn = aws_iam_policy.infra_eng.arn
}
