data "aws_caller_identity" "current" {}

locals {
  # IAM role that Identity Center provisions for the InfraEng permission set,
  # managed by the development base-cluster-layer workspace. Its name carries
  # a random suffix (and, depending on the Identity Center instance region, a
  # region path segment), so trust matches on wildcard patterns. Safe to
  # trust before the role exists, since the CI role trust policy matches on
  # aws:PrincipalArn rather than resolving the principal.
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

module "eks_cluster" {
  environment_name = var.environment_name
  cluster_version  = var.kubernetes_cluster_version
  source           = "../../../../../modules/aws/base-cluster-layer"
  subnet_ids       = module.networking_layer.private_eks_subnet_ids
  vpc_id           = module.networking_layer.vpc.id
  ami_type         = var.ami_type
  node_group_scaling_config = {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }
}

module "networking_layer" {
  environment_name = var.environment_name
  source           = "../../../../../modules/aws/networking"
}
