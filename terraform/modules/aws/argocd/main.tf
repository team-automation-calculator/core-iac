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
  # Atomic since ArgoCD migration Phase 9, once both clusters were installed:
  # a failed upgrade (chart bump, values change, password rotation) rolls back
  # to the previous working ArgoCD instead of leaving a half-upgraded release.
  # It was deliberately non-atomic during the Phase 2 and Phase 8 installs,
  # because `--atomic` uninstalls a failed *first* install, and the realistic
  # failure there was the plan-time EKS token expiring during the 900s wait;
  # a non-atomic retry repaired the install in place. ArgoCD is not
  # customer-facing, so a rollback here never touches the app.
  atomic           = true
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

# ArgoCD migration Phase 5 (docs/argocd-migration-plan.md): the real
# AppProject and Application for the app, created by a second release of the
# argocd-apps chart (CR manifests only, no controller) so the ACM certificate
# ARN is injected by Terraform and never enters this public repository.
# Runbook: docs/argocd-phase-5-adopt-application.md.
locals {
  # The Application name is fixed, not a variable. It feeds
  # spec.source.helm.releaseName below, which feeds app.kubernetes.io/instance
  # in the Deployment's immutable spec.selector.matchLabels
  # (helm/automation-calculator/templates/_helpers.tpl). Any other name makes
  # the Deployment sync fail and rewrites the Service selector to match zero
  # pods.
  app_name = "automation-calculator"

  # Value names verified against the argocd-apps 2.0.7 chart: top-level
  # `projects` and `applications` maps keyed by object name; everything under
  # an entry is passed through to the CR spec with toYaml.
  argocd_apps_values = {
    projects = {
      (local.app_name) = {
        namespace   = var.argocd_namespace
        description = "The automation-calculator app in ${var.environment_name}. Source: this repository only; destination: the ${var.app_namespace} namespace of the local cluster only."
        sourceRepos = [var.app_repo_url]
        destinations = [{
          server    = "https://kubernetes.default.svc"
          namespace = var.app_namespace
        }]
        # Cluster-scoped kinds are allow-listed. The one entry exists for the
        # Application's CreateNamespace=true: gitops-engine runs the namespace
        # PreSync task through the project permission check like any other
        # resource, and an empty whitelist fails the first sync with
        # "resource :Namespace is not permitted" (Phase 3 finding,
        # argocd/scratch/appproject.yaml). The name narrows it to the app
        # namespace; the project cannot create any other namespace.
        clusterResourceWhitelist = [{
          group = ""
          kind  = "Namespace"
          name  = var.app_namespace
        }]
      }
    }

    applications = {
      (local.app_name) = {
        namespace = var.argocd_namespace
        # Deliberately NO resources-finalizer.argocd.argoproj.io: with it,
        # deleting the Application (a Terraform destroy, a helm_release
        # replace, a rename) cascade-deletes the Ingress and therefore the
        # ALB. Deleting this Application must leave every app object in place.
        project = local.app_name
        source = {
          repoURL        = var.app_repo_url
          targetRevision = var.app_target_revision
          path           = var.app_chart_path
          helm = {
            releaseName = local.app_name
            valueFiles = [
              "values.yaml",
              "values-${var.environment_name}.yaml",
            ]
            # Only what must not live in git. Everything else (image tag,
            # host, ALB name, secrets.create=false) comes from the values
            # files above, the same files Terraform's main_rails_app release
            # reads, so the two controllers render the same manifests.
            parameters = [{
              name  = "ingress.certificateArn"
              value = var.app_certificate_arn
            }]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.app_namespace
        }
        # Manual sync by default (no `automated` block). While Terraform still
        # manages the Helm release, two controllers must never reconcile the
        # same Deployment; Phase 6 flips staging after `terraform state rm`.
        syncPolicy = merge(
          { syncOptions = ["CreateNamespace=true"] },
          var.application_automated_sync ? {
            automated = {
              prune    = var.application_prune
              selfHeal = var.application_self_heal
            }
          } : {}
        )
      }
    }
  }
}

resource "helm_release" "argocd_apps" {
  count = var.manage_application ? 1 : 0

  # Unlike the argo-cd release above, this one is atomic: the chart only
  # renders two CRs (AppProject, Application), `wait` returns as soon as the
  # API server accepts them, and a rollback or uninstall on failure touches
  # nothing but those two objects. The Application carries no
  # resources-finalizer, so even an uninstall never cascades to the app's
  # Deployment, Ingress or ALB. A failed first install (typically the
  # AppProject rejected because the CRDs are not ready yet) is simply retried.
  atomic          = true
  chart           = "argocd-apps"
  cleanup_on_fail = false
  name            = "argocd-apps"
  namespace       = var.argocd_namespace
  repository      = "https://argoproj.github.io/argo-helm"
  version         = var.argocd_apps_chart_version
  wait            = true

  values = [yamlencode(local.argocd_apps_values)]

  # The AppProject and Application CRDs come from the argo-cd release.
  depends_on = [helm_release.argocd]
}
