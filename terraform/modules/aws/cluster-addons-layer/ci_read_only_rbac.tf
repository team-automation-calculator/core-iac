# The read-only CI role's EKS access entry carries AmazonEKSViewPolicy, which
# maps to the built-in `view` ClusterRole and covers namespaced resources
# only, and deliberately excludes Secrets. The access entry also places the
# role in var.ci_read_only_kubernetes_group; the ClusterRoles below grant that
# group the two reads the view policy lacks and nothing else:
#
#   * nodes — cluster-scoped, denied by the view policy; needed by
#     `kubectl get nodes` and scripts/argocd_preflight.sh.
#   * secrets, get/list — Helm 3 stores release state in Secrets of type
#     `helm.sh/release.v1`, so without this `helm list` / `helm get manifest`
#     fail with "secrets is forbidden" under the read-only role (identically
#     on every environment, see PR #413). RBAC cannot filter by Secret type
#     or label, so this is read on every Secret in the cluster, including
#     the app's RDS credentials. Accepted because the sensitive Secrets live
#     in the same namespaces as the Helm releases (automation-calculator,
#     kube-system, default), so namespace-scoped Roles would expose the same
#     data while breaking `helm list -A`. No watch, no write.
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

resource "kubernetes_cluster_role_v1" "ci_read_only_helm_releases" {
  metadata {
    name = "ac-ci-read-only-helm-releases"
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "ci_read_only_helm_releases" {
  metadata {
    name = "ac-ci-read-only-helm-releases"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.ci_read_only_helm_releases.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.ci_read_only_kubernetes_group
  }
}
