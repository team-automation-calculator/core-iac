module "app_eks_cluster" {
  name                   = "ac_app_${var.environment_name}"
  kubernetes_version     = var.cluster_version
  endpoint_public_access = true
  access_entries         = var.access_entries

  # Envelope encryption of Kubernetes Secrets in etcd, with a customer-managed
  # KMS key the EKS module creates per cluster (alias eks/ac_app_<env>) and
  # rotates yearly. These three values equal the module's defaults and are
  # what both clusters already run; they are spelled out so that a module
  # upgrade that changes a default shows up as a plan diff instead of silently
  # changing how Secrets (the app Secret, argocd-secret) are stored. Never set
  # encryption_config to null or create_kms_key to false on a live cluster:
  # EKS cannot turn secrets encryption off or change its key, so either one
  # plans a cluster replacement.
  encryption_config = {
    resources = ["secrets"]
  }
  create_kms_key          = true
  enable_kms_key_rotation = true

  # EKS managed add-ons. Until these were registered, the default add-ons were
  # the self-managed objects EKS installs at cluster creation, updated by hand
  # after each control-plane upgrade. That drifted: staging ran kube-proxy
  # 1.32 on a 1.36 control plane, outside the kube-proxy version skew policy
  # (at most three minors behind the API server). A managed add-on makes the
  # version a tfvars pin that is bumped together with cluster_version.
  #
  # vpc-cni and CoreDNS are registered only where their version variables are
  # set (staging since the 2026-11-26 trial re-create). Module v21 creates new
  # clusters with bootstrap_self_managed_addons = false, so a cluster created
  # today has no vpc-cni, CoreDNS or kube-proxy at all: without a managed
  # vpc-cni installed before the node group, the nodes never become Ready and
  # the node group create hangs until it fails. Clusters created under the old
  # default (production) still run the self-managed objects and are unchanged
  # while the variables are null; see docs/dependency-upgrade-plan-2026-q4.md.
  addons = merge({
    kube-proxy = {
      # The explicit pin wins: the module coalesces addon_version before its
      # aws_eks_addon_version lookup, so the version never floats with new
      # EKS builds. most_recent only shapes that unused lookup. Pin the
      # defaultVersion that `aws eks describe-addon-versions --addon-name
      # kube-proxy --kubernetes-version <cluster_version>` reports.
      addon_version = var.kube_proxy_addon_version
      most_recent   = false

      # The add-on adopts the self-managed kube-proxy DaemonSet and ConfigMap
      # that already exist in kube-system, so the create must be allowed to
      # overwrite them; the module default NONE fails the create on conflict.
      resolve_conflicts_on_create = "OVERWRITE"

      # Updates overwrite as well. kube-proxy carries no configuration_values
      # and nothing else in this repo edits it, so any difference between the
      # live objects and the add-on manifest is drift (an earlier hand-edited
      # image, for example) that a pin bump should correct rather than keep.
      # PRESERVE would keep such drift; NONE would fail the update on it.
      resolve_conflicts_on_update = "OVERWRITE"

      # preserve (module default true) leaves the DaemonSet running if this
      # add-on is ever removed from the config, instead of deleting
      # kube-proxy from the cluster.
    }
    },
    var.vpc_cni_addon_version == null ? {} : {
      vpc-cni = {
        addon_version = var.vpc_cni_addon_version
        most_recent   = false

        # Installed before the node group: a node is not Ready until the CNI
        # runs on it, and the node group create waits for Ready nodes.
        before_compute = true

        # OVERWRITE adopts a self-managed aws-node DaemonSet where one exists.
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
      }
    },
    var.coredns_addon_version == null ? {} : {
      coredns = {
        addon_version = var.coredns_addon_version
        most_recent   = false

        # After the node group (the module default): CoreDNS pods need a node.
        # OVERWRITE resets a hand-edited Corefile or replica count.
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
      }
    },
  )

  eks_managed_node_groups = {
    primary = {
      desired_size               = var.node_group_scaling_config.desired_size
      max_size                   = var.node_group_scaling_config.max_size
      min_size                   = var.node_group_scaling_config.min_size
      disk_size                  = 20
      instance_types             = var.node_group_instance_types
      ami_type                   = var.ami_type
      ami_id                     = var.ami_id
      use_custom_launch_template = false
    }
  }

  iam_role_use_name_prefix = false

  source     = "terraform-aws-modules/eks/aws"
  subnet_ids = var.subnet_ids
  version    = "21.29.0"
  vpc_id     = var.vpc_id
}
