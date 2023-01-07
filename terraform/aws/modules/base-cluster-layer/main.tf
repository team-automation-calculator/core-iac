module "app_eks_cluster" {
  cluster_version = var.cluster_version
  cluster_name    = "ac_app_${var.environment_name}"

  eks_managed_node_group_defaults = {
    disk_size      = 20
    instance_types = var.node_group_instance_types
  }

  eks_managed_node_groups = {
    primary = var.node_group_scaling_config
  }

  iam_role_use_name_prefix = false

  manage_aws_auth_configmap = false
  source                    = "terraform-aws-modules/eks/aws"
  subnet_ids                = var.subnet_ids
  version                   = "~> 19.5.1"
  vpc_id                    = var.vpc_id
}
