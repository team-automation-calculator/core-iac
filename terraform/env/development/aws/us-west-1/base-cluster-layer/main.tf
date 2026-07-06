module "ci_iam_role" {
  environment_name = var.environment_name
  source           = "../../../../../modules/aws/ci-iam-role"
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
