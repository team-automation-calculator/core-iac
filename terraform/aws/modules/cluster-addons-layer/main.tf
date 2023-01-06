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
    value = var.eks_cluster_name
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
