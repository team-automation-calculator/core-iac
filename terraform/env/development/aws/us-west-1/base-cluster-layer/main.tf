data "aws_caller_identity" "current" {}

locals {
  # IAM role that Identity Center provisions for this environment's InfraEng
  # permission set. Its name carries a random suffix (and, depending on the
  # Identity Center instance region, a region path segment), so trust matches
  # on wildcard patterns. Safe to trust before the role exists, since the CI
  # role trust policy matches on aws:PrincipalArn rather than resolving the
  # principal.
  sso_permission_set_name = "InfraEng${title(var.environment_name)}"
  sso_infra_eng_role_arn_patterns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_${local.sso_permission_set_name}_*",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_${local.sso_permission_set_name}_*",
  ]
}

module "ci_iam_role" {
  environment_name       = var.environment_name
  source                 = "../../../../../modules/aws/ci-iam-role"
  trusted_principal_arns = concat(local.sso_infra_eng_role_arn_patterns, var.ci_trusted_principal_arns)
}

# Per-environment IAM Identity Center access for infrastructure engineers
# (Google Workspace federated): each environment's workspace creates its own
# InfraEng<Env> permission set scoped to that environment's CI role. Runs
# against us-east-1, where the Identity Center organization instance lives.
# Gated off until the Google Workspace identity provider is connected and
# the user is provisioned — manual console steps.
module "sso_infra_eng" {
  count            = var.enable_sso_infra_eng ? 1 : 0
  environment_name = var.environment_name
  source           = "../../../../../modules/aws/sso-infra-eng"
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

  # Grants the CI Terraform role kubectl/Helm access to the cluster API.
  # Human InfraEng access flows through the same role: SSO users assume it
  # (see ci_iam_role trust policy), so no per-user entries are needed.
  access_entries = {
    ci_terraform = {
      principal_arn = module.ci_iam_role.role_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

module "networking_layer" {
  environment_name = var.environment_name
  source           = "../../../../../modules/aws/networking"
}
