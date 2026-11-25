locals {
  shared_workspace_tags = ["automation-calculator", var.environment_name]

  # What a push to main must touch for the two cluster workspaces to run.
  #
  # trigger_on_shared_code = true (staging): the working directory plus the
  # shared module directories and the app chart, as trigger prefixes. A module
  # or chart change applies here as soon as it merges.
  #
  # trigger_on_shared_code = false (production): only this environment's own
  # files, as trigger patterns: its working directory and, for the add-ons
  # layer, its chart values file. A module or chart change merged to main does
  # not run here; it reaches this environment with the next pull request that
  # changes one of those files (docs/promotion.md). Patterns are used because
  # a prefix names a directory and the values file is a single file; the two
  # arguments are mutually exclusive, so the unused one is null.
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
    : [
      "/${var.cluster_addons_layer_working_directory}/**/*",
      "/${var.app_chart_directory}/values-${var.environment_name}.yaml",
    ]
  )
}
