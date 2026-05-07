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
