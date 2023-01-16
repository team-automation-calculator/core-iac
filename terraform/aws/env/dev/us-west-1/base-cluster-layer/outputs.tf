output "private_eks_subnet_ids" {
  description = "The private subnet ids in the VPC"
  value       = module.networking_layer.private_eks_subnet_ids
}
