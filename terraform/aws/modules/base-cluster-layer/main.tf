module "app_eks_cluster" {
  cluster_version = var.cluster_version
  cluster_name    = "ac_app_${var.environment_name}"
  cluster_security_group_additional_rules = {
    alb_webhook_ingress = {
      description                = "Allow traffic for ALB webhooks on ingress creation"
      type                       = "ingress"
      source_node_security_group = true
      from_port                  = 9443
      to_port                    = 9443
      protocol                   = "tcp"
    },
    alb_webhook_egress = {
      description                = "Allow traffic for ALB webhooks on ingress creation"
      type                       = "egress"
      source_node_security_group = true
      from_port                  = 9443
      to_port                    = 9443
      protocol                   = "tcp"
    }
  }

  eks_managed_node_group_defaults = {
    disk_size      = 20
    instance_types = var.node_group_instance_types
  }

  eks_managed_node_groups = {
    primary = var.node_group_scaling_config
  }

  enable_irsa               = true
  manage_aws_auth_configmap = false
  source                    = "terraform-aws-modules/eks/aws"
  subnet_ids                = var.subnet_ids
  version                   = "~> 18.0"
  vpc_id                    = var.vpc_id
}