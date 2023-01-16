output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks_cluster.eks_cluster_name
}

output "eks_cluster_oidc_provider_arn" {
  description = "The ARN of the EKS cluster OIDC provider"
  value       = module.eks_cluster.eks_cluster_oidc_provider_arn
}

output "eks_cluster_launch_template_name" {
  description = "The name of the EKS cluster launch template"
  value       = module.eks_cluster.eks_cluster_launch_template_name
}

output "environment_name" {
  description = "The name of the environment"
  value       = var.environment_name
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
