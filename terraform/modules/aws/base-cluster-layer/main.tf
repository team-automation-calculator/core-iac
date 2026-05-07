module "app_eks_cluster" {
  name               = "ac_app_${var.environment_name}"
  kubernetes_version = var.cluster_version
  endpoint_public_access = true

  eks_managed_node_groups = {
    primary = {
      desired_size               = var.node_group_scaling_config.desired_size
      max_size                   = var.node_group_scaling_config.max_size
      min_size                   = var.node_group_scaling_config.min_size
      disk_size                  = 20
      instance_types             = var.node_group_instance_types
      ami_type                   = var.ami_type
      ami_id                     = var.ami_id
      use_custom_launch_template = false
    }
  }

  iam_role_use_name_prefix = false

  source     = "terraform-aws-modules/eks/aws"
  subnet_ids = var.subnet_ids
  version    = "~> 21.0"
  vpc_id     = var.vpc_id
}
