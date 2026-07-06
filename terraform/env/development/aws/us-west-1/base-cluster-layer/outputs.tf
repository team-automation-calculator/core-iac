output "ci_iam_role_arn" {
  description = "The ARN of the IAM role CI assumes to manage Terraform-provisioned AWS resources"
  value       = module.ci_iam_role.role_arn
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks_cluster.eks_cluster_name
}

output "eks_cluster_oidc_provider_arn" {
  description = "The ARN of the EKS cluster OIDC provider"
  value       = module.eks_cluster.eks_cluster_oidc_provider_arn
}

output "environment_name" {
  description = "The name of the environment"
  value       = var.environment_name
}

output "infra_eng_role_arn" {
  description = "The ARN of the account-global infra_eng IAM role"
  value       = module.infra_eng_iam.role_arn
}

output "infra_eng_user_arn" {
  description = "The ARN of the infra engineer IAM user allowed to assume the infra_eng role"
  value       = module.infra_eng_iam.user_arn
}

output "private_eks_subnet_ids" {
  description = "The private subnet ids in the VPC"
  value       = module.networking_layer.private_eks_subnet_ids
}

output "project_tag" {
  description = "The project tag"
  value       = var.project_tag
}

output "vpc_id" {
  description = "The VPC ID"
  value       = module.networking_layer.vpc.id
}
