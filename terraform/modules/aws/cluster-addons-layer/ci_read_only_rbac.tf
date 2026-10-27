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
