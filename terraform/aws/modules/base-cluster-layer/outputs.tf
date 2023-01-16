output "eks_cluster_name" {
  value = module.app_eks_cluster.cluster_name
}

output "eks_cluster_api_endpoint" {
  value = module.app_eks_cluster.cluster_endpoint
}

output "eks_cluster_cert_data" {
  value = module.app_eks_cluster.cluster_certificate_authority_data
}

output "eks_cluster_oidc_provider_arn" {
  value = module.app_eks_cluster.oidc_provider_arn
}

output "eks_cluster_launch_template_name" {
  value = module.app_eks_cluster.eks_managed_node_groups.primary.launch_template_name
}
