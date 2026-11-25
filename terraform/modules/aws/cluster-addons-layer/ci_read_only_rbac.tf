# The read-only CI role's EKS access entry carries AmazonEKSViewPolicy, which
# maps to the built-in `view` ClusterRole and covers namespaced resources
# only. Cluster-scoped reads such as `kubectl get nodes` (used by
# scripts/argocd_preflight.sh) are denied. The access entry also places the
# role in var.ci_read_only_kubernetes_group; this ClusterRole grants that
# group read-only access to nodes and nothing else.
resource "kubernetes_cluster_role_v1" "ci_read_only_nodes" {
  metadata {
    name = "ac-ci-read-only-nodes"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "ci_read_only_nodes" {
  metadata {
    name = "ac-ci-read-only-nodes"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.ci_read_only_nodes.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.ci_read_only_kubernetes_group
  }
}

# AmazonEKSViewPolicy does not cover custom resources either, so the read-only
# role could not read the ArgoCD Application's sync and health status
# (`kubectl -n argocd get applications.argoproj.io automation-calculator`),
# which a rollout check needs. This ClusterRole grants the same group read-only
# access to ArgoCD Applications and AppProjects and nothing else. Neither
# object holds a secret: the Application carries the repo URL, the values file
# names and the ACM certificate ARN.
#
# It is a ClusterRole, not a Role in the argocd namespace, on purpose: RBAC
# rules are plain strings, so these two resources apply whether or not the
# argocd namespace and the argoproj.io CRDs exist (argocd_enabled is per
# environment) and need no dependency on the argocd module.
#
# Secrets are deliberately not granted, so `helm list` / `helm get manifest`
# and the `argocd` CLI (port-forward plus the admin login) still need the
# read-write role. Helm keeps release state in Secrets, and RBAC cannot scope a
# grant to Helm's release Secrets only: `list secrets` would expose the app
# Secret, argocd-secret and the add-ons' Secrets to the read-only persona.
resource "kubernetes_cluster_role_v1" "ci_read_only_argocd" {
  metadata {
    name = "ac-ci-read-only-argocd"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications", "appprojects"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "ci_read_only_argocd" {
  metadata {
    name = "ac-ci-read-only-argocd"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.ci_read_only_argocd.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.ci_read_only_kubernetes_group
  }
}
