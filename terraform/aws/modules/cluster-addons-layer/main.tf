module "aws_load_balancer_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${var.environment_name}_eks_lb"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = "${var.eks_cluster_oidc_provider_arn}"
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "aws_load_balancer_controller_service_account" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.aws_load_balancer_controller_irsa_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  atomic = true
  chart  = "aws-load-balancer-controller"
  depends_on = [
    kubernetes_service_account.aws_load_balancer_controller_service_account
  ]
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"

  set {
    name  = "clusterName"
    value = var.eks_cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_load_balancer_controller_service_account.metadata[0].name
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  version = "2.4.0"
}

resource "kubernetes_secret_v1" "aws_load_balancer_controller_service_account" {
  metadata {
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.aws_load_balancer_controller_service_account.metadata[0].name
    }
    name      = "aws-load-balancer-controller-token"
    namespace = "kube-system"
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "helm_release" "external-dns" {
  depends_on = [
    kubernetes_service_account.external_dns_service_account
  ]
  name       = "external-dns"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "external-dns"
  namespace  = "kube-system"

  set {
    name  = "provider"
    value = "aws"
  }

  set {
    name  = "aws.zoneType"
    value = "public"
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
}

module "external_dns_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                  = "${var.environment_name}_eks_external_dns"
  attach_external_dns_policy = true

  oidc_providers = {
    main = {
      provider_arn               = "${var.eks_cluster_oidc_provider_arn}"
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

resource "kubernetes_service_account" "external_dns_service_account" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "external-dns"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.external_dns_irsa_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "kubernetes_secret_v1" "external_dns_service_account" {
  metadata {
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.external_dns_service_account.metadata[0].name
    }
    name      = "external-dns-token"
    namespace = "kube-system"
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
