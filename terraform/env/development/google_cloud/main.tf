terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.51.0"
    }
  }
}

#Note credentials are set using the GOOGLE_CREDENTIALS environment variable to enable consistent auth locally and on tf cloud
provider "google" {
  project = var.GOOGLE_PROJECT_ID
  region  = var.region
  zone    = var.zone
}

data "tfe_outputs" "cluster_addons_state" {
  organization = var.tf_cloud_organization_name
  workspace    = var.tfe_cluster_addons_workspace_name
}

module "google_cloud" {
  environment_name = var.environment_name
  project_id       = var.GOOGLE_PROJECT_ID
  redirect_uri     = data.tfe_outputs.cluster_addons_state.nonsensitive_values.app_hostname
  source           = "../../../modules/google_cloud"
  support_email    = var.GOOGLE_SUPPORT_EMAIL
}
