locals {
  # Value names verified against the argo-cd 10.11.6 chart's values.yaml.
  # No IRSA (the repo is public and ArgoCD makes no AWS calls), no Ingress (UI
  # access is a kubectl port-forward; see docs/argocd-phase-2-install.md). The
  # admin password is generated here and set from its bcrypt hash (see
  # random_password.argocd_admin and the set_sensitive entries below), so the
  # chart does not generate one into argocd-initial-admin-secret.
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

  # Admin password as a bcrypt hash, rendered by the chart into admin.password
  # / admin.passwordMtime of the argocd-secret Secret. Passed through
  # set_sensitive (not values) so plan output redacts it. (helm provider 3
  # syntax: set_sensitive is a list attribute, not repeated blocks.)
  set_sensitive = [
    {
      name  = "configs.secret.argocdServerAdminPassword"
      value = random_password.argocd_admin.bcrypt_hash
    },
    {
      name  = "configs.secret.argocdServerAdminPasswordMtime"
      value = time_static.argocd_admin_password.rfc3339
    },
  ]
}

# The admin password. bcrypt_hash is computed once when the resource is
# created and then read from state, so it is stable across runs (unlike the
# bcrypt() function, which salts differently on every call and would upgrade
# ArgoCD on every run). No special characters, so the password pastes into a
# shell and the argocd CLI prompt without quoting. The plaintext lives in the
# workspace state, like the database password in main_rails_app; read it from
# the env config's argocd_admin_password output.
resource "random_password" "argocd_admin" {
  length  = 32
  special = false

  keepers = {
    rotation = var.argocd_admin_password_rotation
  }
}

# The password's mtime. ArgoCD invalidates sessions issued before it, so it
# must change exactly when the password does and not on any other run: the
# chart's default (the render time) would log everyone out on every upgrade.
resource "time_static" "argocd_admin_password" {
  triggers = {
    rotation = var.argocd_admin_password_rotation
  }
}
