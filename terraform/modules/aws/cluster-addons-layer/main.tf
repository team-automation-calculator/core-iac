module "aws_load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = "${var.environment_name}_eks_lb"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = "${var.eks_cluster_oidc_provider_arn}"
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account_v1" "aws_load_balancer_controller_service_account" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.aws_load_balancer_controller_irsa_role.arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  atomic = true
  chart  = "aws-load-balancer-controller"
  depends_on = [
    kubernetes_service_account_v1.aws_load_balancer_controller_service_account
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
    value = kubernetes_service_account_v1.aws_load_balancer_controller_service_account.metadata[0].name
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "image.repository"
    value = "public.ecr.aws/eks/aws-load-balancer-controller"
  }

  # Watch discovery.k8s.io/v1 EndpointSlices instead of the v1 Endpoints API,
  # which is deprecated as of Kubernetes 1.33. Defaults to false in 2.x.
  set {
    name  = "enableEndpointSlices"
    value = "true"
  }

  # Chart 1.5.0+ defaults this to true, which makes the controller claim every
  # new Service of type LoadBalancer. Keep the pre-upgrade behavior.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }

  # Chart CRDs live in crds/, which helm upgrade never touches; apply them
  # manually before upgrading (see the PR that bumped this from 1.4.6).
  version = "1.17.1"
}

resource "kubernetes_secret_v1" "aws_load_balancer_controller_service_account" {
  metadata {
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.aws_load_balancer_controller_service_account.metadata[0].name
    }
    name      = "aws-load-balancer-controller-token"
    namespace = "kube-system"
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "helm_release" "external-dns" {
  depends_on = [
    kubernetes_service_account_v1.external_dns_service_account
  ]
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.21.1"
  namespace  = "kube-system"

  set {
    name  = "provider.name"
    value = "aws"
  }

  set {
    name  = "extraArgs[0]"
    value = "--aws-zone-type=public"
  }

  # Chart defaults (policy=upsert-only, txt registry, owner id "default")
  # match the previous Bitnami deployment, so existing Route 53 TXT
  # ownership records stay valid across the migration.
  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }

  # Only set txtPrefix when configured, so environments without it render
  # exactly as before (no helm diff). Changing it orphans the existing TXT
  # ownership records: pre-create the new-format records first, see
  # docs/external-dns-txt-prefix-migration.md.
  dynamic "set" {
    for_each = var.external_dns_txt_prefix == "" ? [] : [var.external_dns_txt_prefix]
    content {
      name  = "txtPrefix"
      type  = "string"
      value = set.value
    }
  }
}

module "external_dns_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                          = "${var.environment_name}_eks_external_dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/*"]

  oidc_providers = {
    main = {
      provider_arn               = "${var.eks_cluster_oidc_provider_arn}"
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

resource "kubernetes_service_account_v1" "external_dns_service_account" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "external-dns"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.external_dns_irsa_role.arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "kubernetes_secret_v1" "external_dns_service_account" {
  metadata {
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.external_dns_service_account.metadata[0].name
    }
    name      = "external-dns-token"
    namespace = "kube-system"
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "helm_release" "metrics-server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.8.3"
}
