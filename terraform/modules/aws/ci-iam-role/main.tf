data "aws_caller_identity" "current" {}

locals {
  role_name   = "ac_ci_terraform_${var.environment_name}"
  policy_name = "ac_ci_terraform_${var.environment_name}"

  read_only_role_name   = "ac_ci_terraform_${var.environment_name}_read_only"
  read_only_policy_name = "ac_ci_terraform_${var.environment_name}_read_only"

  # When no principals are listed, fall back to a sentinel in a different
  # (nonexistent) account. The trust statements below are already scoped to
  # this account's principals, so the sentinel can never match and the role is
  # assumable by no one until ARNs are explicitly added.
  no_principals_sentinel = ["arn:aws:iam::000000000000:root"]

  trusted_principal_arns = (
    length(var.trusted_principal_arns) > 0
    ? var.trusted_principal_arns
    : local.no_principals_sentinel
  )

  read_only_trusted_principal_arns = (
    length(var.read_only_trusted_principal_arns) > 0
    ? var.read_only_trusted_principal_arns
    : local.no_principals_sentinel
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

# Same trust shape as the read-write role above, gated on its own allowlist.
data "aws_iam_policy_document" "assume_role_read_only" {
  statement {
    sid     = "AllowReadOnlyPrincipalsToAssume"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.read_only_trusted_principal_arns
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

resource "aws_iam_role" "ci_read_only" {
  name                 = local.read_only_role_name
  description          = "Assumed to run read-only Terraform plans and inspect resources for the ${var.environment_name} environment"
  assume_role_policy   = data.aws_iam_policy_document.assume_role_read_only.json
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

# Read-only counterpart of ci_permissions: the same services, restricted to
# the Describe/Get/List action verbs uniformly. IAM ignores verb patterns a
# service doesn't define, so the uniform shape is harmless and keeps the two
# statements easy to diff against the read-write list. Enough for terraform
# plan and for inspecting resources; no mutation verbs.
data "aws_iam_policy_document" "ci_read_only_permissions" {
  statement {
    sid = "ReadInfrastructureServices"
    actions = [
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
    resources = ["*"]
  }

  statement {
    sid = "ReadIamForTerraformPlan"
    actions = [
      "iam:Get*",
      "iam:List*",
    ]
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

resource "aws_iam_policy" "ci_read_only" {
  name        = local.read_only_policy_name
  description = "Read-only permissions to plan and inspect Terraform-provisioned AWS resources in ${var.environment_name}"
  policy      = data.aws_iam_policy_document.ci_read_only_permissions.json

  tags = {
    Project = "automation_calculator"
  }
}

resource "aws_iam_role_policy_attachment" "ci" {
  role       = aws_iam_role.ci.name
  policy_arn = aws_iam_policy.ci.arn
}

resource "aws_iam_role_policy_attachment" "ci_read_only" {
  role       = aws_iam_role.ci_read_only.name
  policy_arn = aws_iam_policy.ci_read_only.arn
}
