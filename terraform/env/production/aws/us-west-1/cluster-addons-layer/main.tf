data "aws_eks_cluster" "target_cluster" {
  name = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_name
}

data "aws_eks_cluster_auth" "target_cluster_auth" {
  name = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_name
}

data "tfe_outputs" "base_layer_state" {
  organization = var.tf_cloud_organization_name
  workspace    = var.tfe_base_layer_workspace_name
}

module "cluster_addons" {
  alarm_email                   = var.alarm_email
  cloudwatch_alarms_enabled     = true
  environment_name              = data.tfe_outputs.base_layer_state.nonsensitive_values.environment_name
  eks_cluster_name              = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_name
  eks_cluster_api_endpoint      = data.aws_eks_cluster.target_cluster.endpoint
  eks_cluster_cert_data         = base64decode(data.aws_eks_cluster.target_cluster.certificate_authority.0.data)
  eks_cluster_oidc_provider_arn = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_oidc_provider_arn
  source                        = "../../../../../modules/aws/cluster-addons-layer"
  vpc_id                        = data.tfe_outputs.base_layer_state.nonsensitive_values.vpc_id
}

module "main_rails_app" {
  automation_calculator_helm_release_local_path = "../../../../../../helm/automation-calculator"
  app_version                                   = var.app_version
  automation_calculator_app_host                = var.automation_calculator_app_host
  db_engine_version                             = var.db_engine_version
  db_security_group_ids                         = [data.aws_eks_cluster.target_cluster.vpc_config[0].cluster_security_group_id]
  db_subnet_group_ids                           = data.tfe_outputs.base_layer_state.nonsensitive_values.private_eks_subnet_ids
  db_port                                       = 5432
  depends_on = [
    module.cluster_addons
  ]
  environment_name        = data.tfe_outputs.base_layer_state.nonsensitive_values.environment_name
  github_oauth_app_id     = var.github_oauth_app_id
  github_oauth_app_secret = var.github_oauth_app_secret
  google_oauth_app_id     = var.google_oauth_app_id
  google_oauth_app_secret = var.google_oauth_app_secret
  source                  = "../../../../../modules/aws/main_rails_app"
  vpc_id                  = data.tfe_outputs.base_layer_state.nonsensitive_values.vpc_id
}
