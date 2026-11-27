# One-time adoption of the vpc-cni and CoreDNS managed add-ons that were
# created by hand on 2026-11-26, during the trial re-create of staging, to let
# the new node group become Ready (module v21 installs no CNI; see the comment
# on addons in modules/aws/base-cluster-layer/main.tf).
#
# Delete this file once the import has applied, and before staging is
# destroyed again: on a re-created cluster Terraform creates both add-ons
# itself, and an import block whose object does not exist fails the plan.
import {
  to = module.eks_cluster.module.app_eks_cluster.aws_eks_addon.before_compute["vpc-cni"]
  id = "ac_app_staging:vpc-cni"
}

import {
  to = module.eks_cluster.module.app_eks_cluster.aws_eks_addon.this["coredns"]
  id = "ac_app_staging:coredns"
}
