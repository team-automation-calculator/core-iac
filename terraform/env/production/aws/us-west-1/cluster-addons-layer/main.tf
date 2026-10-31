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
  external_dns_txt_prefix       = var.external_dns_txt_prefix
  source                        = "../../../../../modules/aws/cluster-addons-layer"
  vpc_id                        = data.tfe_outputs.base_layer_state.nonsensitive_values.vpc_id
}

module "argocd" {
  argocd_admin_password_bcrypt_hash = var.argocd_admin_password_bcrypt_hash
  argocd_admin_password_mtime       = var.argocd_admin_password_mtime
  count                             = var.argocd_enabled ? 1 : 0
  depends_on = [
    module.cluster_addons
  ]
  # Phase 5: the Application's only Terraform-injected value. The reference
  # orders this module after the ACM certificate, not after the whole
  # main_rails_app module (RDS, the namespace and the Secret are unrelated).
  app_certificate_arn = module.main_rails_app.automation_calculator_app_certificate_arn
  app_repo_url        = var.app_repo_url
  # Phase 6/8: automated sync was enabled on staging only once its Helm release
  # had left Terraform (Phase 9 removed the release from the module for good);
  # production leaves all three at their false defaults: manual sync.
  application_automated_sync = var.argocd_application_automated_sync
  application_prune          = var.argocd_application_prune
  application_self_heal      = var.argocd_application_self_heal
  environment_name           = data.tfe_outputs.base_layer_state.nonsensitive_values.environment_name
  manage_application         = var.argocd_manage_application
  source                     = "../../../../../modules/aws/argocd"
}

module "main_rails_app" {
  automation_calculator_app_host = var.automation_calculator_app_host
  db_engine_version              = var.db_engine_version
  db_security_group_ids          = [data.aws_eks_cluster.target_cluster.vpc_config[0].cluster_security_group_id]
  db_subnet_group_ids            = data.tfe_outputs.base_layer_state.nonsensitive_values.private_eks_subnet_ids
  db_port                        = 5432
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
