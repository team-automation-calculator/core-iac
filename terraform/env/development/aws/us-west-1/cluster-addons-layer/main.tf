terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.16"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "0.68.2"
    }
  }
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "team-automation-calculator"

    workspaces {
      name = "ac_app_development_cluster_addons_layer"
    }
  }
}

data "aws_eks_cluster" "target_cluster" {
  name = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_name
}

data "aws_eks_cluster_auth" "target_cluster_auth" {
  name = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_name
}

data "aws_launch_template" "target_cluster_launch_template" {
  name = data.tfe_outputs.base_layer_state.nonsensitive_values.eks_cluster_launch_template_name
}

data "tfe_outputs" "base_layer_state" {
  organization = var.tf_cloud_organization_name
  workspace    = var.tfe_base_layer_workspace_name
}

module "cluster_addons" {
  alarm_email                   = var.alarm_email
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
  automation_calculator_app_host                = var.automation_calculator_app_host
  db_engine_version                             = var.db_engine_version
  db_security_group_ids                         = data.aws_launch_template.target_cluster_launch_template.vpc_security_group_ids
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
