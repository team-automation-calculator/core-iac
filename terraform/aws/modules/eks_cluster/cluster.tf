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

  manage_aws_auth_configmap = false
  source                    = "terraform-aws-modules/eks/aws"
  subnet_ids                = var.subnet_ids
  version                   = "~> 18.0"
  vpc_id                    = var.vpc_id
}

module "alb_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${var.environment_name}_alb_controller_irsa_role"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.app_eks_cluster.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "service-account" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.alb_controller_irsa_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "alb-ingress-controller" {
  atomic     = true
  chart      = "aws-load-balancer-controller"
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"

  set {
    name  = "clusterName"
    value = module.app_eks_cluster.cluster_name
  }

  version = "1.4.6"
}

