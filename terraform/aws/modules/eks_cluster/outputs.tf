output "eks_cluster_name" {
  value = module.app_eks_cluster.cluster_name
}

output "eks_cluster_id" {
  value = module.app_eks_cluster.cluster_id
}

output "eks_cluster_api_endpoint" {
  value = module.app_eks_cluster.cluster_endpoint
}

output "eks_cluster_cert_data" {
  value = module.app_eks_cluster.cluster_certificate_authority_data
}
