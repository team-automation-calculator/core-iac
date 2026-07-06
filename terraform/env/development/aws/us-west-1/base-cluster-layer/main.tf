data "aws_caller_identity" "current" {}

locals {
  # IAM role that Identity Center provisions for the InfraEng permission set.
  # Its name carries a random suffix (and, depending on the Identity Center
  # instance region, a region path segment), so trust matches on wildcard
  # patterns. Safe to trust before the role exists, since the CI role trust
  # policy matches on aws:PrincipalArn rather than resolving the principal.
  sso_infra_eng_role_arn_patterns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_InfraEng_*",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_InfraEng_*",
  ]
}

module "ci_iam_role" {
  environment_name       = var.environment_name
  source                 = "../../../../../modules/aws/ci-iam-role"
  trusted_principal_arns = concat(local.sso_infra_eng_role_arn_patterns, var.ci_trusted_principal_arns)
}

# Account-global IAM Identity Center access for infrastructure engineers
# (Google Workspace federated). All environments share the AWS account, so
# this is created once, here in the development workspace. Runs against
# us-east-1, where the Identity Center organization instance lives. Gated
# off until the Google Workspace identity provider is connected and the
# user is provisioned — manual console steps.
module "sso_infra_eng" {
  count  = var.enable_sso_infra_eng ? 1 : 0
  source = "../../../../../modules/aws/sso-infra-eng"
  providers = {
    aws = aws.us_east_1
  }
}

module "eks_cluster" {
  environment_name = var.environment_name
  source           = "../../../../../modules/aws/base-cluster-layer"
  subnet_ids       = module.networking_layer.private_eks_subnet_ids
  cluster_version  = var.kubernetes_cluster_version
  vpc_id           = module.networking_layer.vpc.id
  ami_type         = var.ami_type
}

module "networking_layer" {
  environment_name = var.environment_name
  source           = "../../../../../modules/aws/networking"
}
