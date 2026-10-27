locals {
  # Value names verified against the argo-cd 10.11.6 chart's values.yaml.
  # No IRSA (the repo is public and ArgoCD makes no AWS calls), no Ingress (UI
  # access is a kubectl port-forward; see docs/argocd-phase-2-install.md). The
  # admin password is optionally set from a bcrypt hash held in TFC (see
  # variables.tf and the set_sensitive blocks below); otherwise the chart
  # generates one into argocd-initial-admin-secret.
  argocd_values = {
    # Components we do not use. The chart dropped `applicationSet.enabled` in
    # 7.0 (the controller is always rendered), so scale it to zero instead:
    # the Deployment exists but adds no pod. That keeps ArgoCD at four pods:
    # application controller, repo server, server, redis.
    dex           = { enabled = false }
    notifications = { enabled = false }
    "redis-ha"    = { enabled = false }
    applicationSet = {
      replicas = 0
    }

    configs = {
      params = {
        # Serve plain HTTP: the UI/API is only reached through a port-forward
        # over the EKS API, never from the internet.
        "server.insecure" = true
      }
    }

    # Single replicas on a single-node cluster. Memory limits only; CPU is
    # left unlimited so a slow sync does not get throttled.
    controller = {
      replicas = 1
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }
    repoServer = {
      replicas = 1
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    server = {
      replicas = 1
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    redis = {
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
  }
}

resource "helm_release" "argocd" {
  # No automatic rollback: an ArgoCD install failure is not customer-facing,
  # and a rolled-back release still writes the new values into Terraform state
  # (every later plan shows 0 changes while the cluster is untouched). Leave
  # the failed release in place so it can be inspected and retried.
  atomic           = false
  chart            = "argo-cd"
  cleanup_on_fail  = false
  create_namespace = true
  name             = "argocd"
  namespace        = var.argocd_namespace
  repository       = "https://argoproj.github.io/argo-helm"
  timeout          = 900
  version          = var.argocd_chart_version
  wait             = true

  values = [yamlencode(local.argocd_values)]

  # Admin password as a pre-computed bcrypt hash, rendered by the chart into
  # admin.password / admin.passwordMtime of the argocd-secret Secret. Passed
  # through set_sensitive (not values) so plan output redacts it. Both blocks
  # are absent when the hash is null, which leaves the chart's generated
  # password behaviour untouched.
  dynamic "set_sensitive" {
    for_each = var.argocd_admin_password_bcrypt_hash == null ? [] : [1]
    content {
      name  = "configs.secret.argocdServerAdminPassword"
      value = var.argocd_admin_password_bcrypt_hash
    }
  }

  dynamic "set_sensitive" {
    for_each = var.argocd_admin_password_mtime == null ? [] : [1]
    content {
      name  = "configs.secret.argocdServerAdminPasswordMtime"
      value = var.argocd_admin_password_mtime
    }
  }
}
