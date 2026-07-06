data "aws_caller_identity" "current" {}

locals {
  role_name   = "ac_ci_terraform_${var.environment_name}"
  policy_name = "ac_ci_terraform_${var.environment_name}"

  # When no principals are listed, fall back to a sentinel in a different
  # (nonexistent) account. The trust statement below is already scoped to this
  # account's principals, so the sentinel can never match and the role is
  # assumable by no one until ARNs are explicitly added.
  trusted_principal_arns = (
    length(var.trusted_principal_arns) > 0
    ? var.trusted_principal_arns
    : ["arn:aws:iam::000000000000:root"]
  )
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowCiPrincipalsToAssume"
    actions = ["sts:AssumeRole"]

    # The account root principal only scopes trust to principals in this
    # account; the aws:PrincipalArn condition below restricts assumption to
    # the explicit allowlist. Matching on ARN instead of listing principals
    # directly keeps the trust policy valid when a listed principal does not
    # exist yet, and avoids silent invalidation if one is deleted/recreated.
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    # ArnLike so trusted ARNs may contain wildcards (e.g. the random suffix
    # in Identity Center's AWSReservedSSO_* role names); exact ARNs still
    # match identically.
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = local.role_name
  description          = "Assumed by CI to run Terraform plans and applies for the ${var.environment_name} environment"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_iam_policy_document" "ci_permissions" {
  statement {
    sid = "ManageInfrastructureServices"
    actions = [
      "acm:*",
      "autoscaling:*",
      "cloudwatch:*",
      "ec2:*",
      "eks:*",
      "elasticloadbalancing:*",
      "kms:*",
      "logs:*",
      "rds:*",
      "route53:*",
      "route53domains:*",
      "sns:*",
    ]
    resources = ["*"]
  }

  # The CI role can manage all IAM, including itself: it sits at the top of
  # the user management chain, so Terraform applies run by CI must be able to
  # update this role and its policy.
  statement {
    sid       = "ManageIamForTerraform"
    actions   = ["iam:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci" {
  name        = local.policy_name
  description = "Permissions for CI to manage Terraform-provisioned AWS resources in ${var.environment_name}"
  policy      = data.aws_iam_policy_document.ci_permissions.json

  tags = {
    Project = "automation_calculator"
  }
}

resource "aws_iam_role_policy_attachment" "ci" {
  role       = aws_iam_role.ci.name
  policy_arn = aws_iam_policy.ci.arn
}
