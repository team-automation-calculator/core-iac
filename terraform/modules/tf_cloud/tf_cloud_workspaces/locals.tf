locals {
  shared_workspace_tags = ["automation-calculator", var.environment_name]

  # What a push to main must touch for the two cluster workspaces to run.
  #
  # trigger_on_shared_code = true (staging): the working directory plus the
  # shared module directories, as trigger prefixes. A module change applies
  # here as soon as it merges.
  #
  # trigger_on_shared_code = false (production): only this environment's own
  # working directory, as a trigger pattern. A module change merged to main
  # does not run here; it reaches this environment with the next pull request
  # that changes a file in that directory (docs/promotion.md). The two
  # arguments are mutually exclusive, so the unused one is null.
  #
  # The app chart triggers neither since ArgoCD migration Phase 9: ArgoCD
  # deploys it from main and Terraform reads nothing from it.
  base_cluster_layer_trigger_prefixes = (
    var.trigger_on_shared_code
    ? concat([var.base_cluster_layer_working_directory], var.base_cluster_layer_module_directories)
    : null
  )
  base_cluster_layer_trigger_patterns = (
    var.trigger_on_shared_code
    ? null
    : ["/${var.base_cluster_layer_working_directory}/**/*"]
  )

  cluster_addons_layer_trigger_prefixes = (
    var.trigger_on_shared_code
    ? concat([var.cluster_addons_layer_working_directory], var.cluster_addons_layer_module_directories)
    : null
  )
  cluster_addons_layer_trigger_patterns = (
    var.trigger_on_shared_code
    ? null
    : ["/${var.cluster_addons_layer_working_directory}/**/*"]
  )
}
