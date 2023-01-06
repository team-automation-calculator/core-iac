module "app_eks_cluster" {
  cluster_version = var.cluster_version
  cluster_name    = "ac_app_${var.environment_name}"
  cluster_security_group_additional_rules = [
    {
      security_groups = [module.app_eks_cluster.cluster_security_group_id]
      from_port       = 9443
      to_port         = 9443
      protocol        = "tcp"
    }
  ]

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

resource "kubernetes_service_account" "alb-controller-service-account" {
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
  atomic = true
  chart  = "aws-load-balancer-controller"
  depends_on = [
    kubernetes_service_account.alb-controller-service-account
  ]
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"

  set {
    name  = "clusterName"
    value = module.app_eks_cluster.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  version = "1.4.6"
}

resource "kubernetes_secret_v1" "alb_ingress_controller_irsa_token" {
  metadata {
    annotations = {
      "kubernetes.io/service-account.name" = "aws-load-balancer-controller"
    }
    name      = "aws-load-balancer-controller-token"
    namespace = "kube-system"
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

