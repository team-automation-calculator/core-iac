output "eks_cluster_id" {
  value = aws_eks_cluster.app_eks_cluster.id
}

output "eks_cluster_api_endpoint" {
  value = aws_eks_cluster.app_eks_cluster.endpoint
}

output "eks_cluster_cert_data" {
  value = aws_eks_cluster.app_eks_cluster.certificate_authority
}
