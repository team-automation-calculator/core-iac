module "app_eks_cluster" {
  name                   = "ac_app_${var.environment_name}"
  kubernetes_version     = var.cluster_version
  endpoint_public_access = true
  access_entries         = var.access_entries

  # EKS managed add-ons. Until these were registered, the default add-ons were
  # the self-managed objects EKS installs at cluster creation, updated by hand
  # after each control-plane upgrade. That drifted: staging ran kube-proxy
  # 1.32 on a 1.36 control plane, outside the kube-proxy version skew policy
  # (at most three minors behind the API server). A managed add-on makes the
  # version a tfvars pin that is bumped together with cluster_version.
  # CoreDNS and vpc-cni are not registered yet; see the follow-ups in
  # docs/dependency-upgrade-plan-2026-q4.md.
  addons = {
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
  }

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
