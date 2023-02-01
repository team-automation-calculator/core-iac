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

module "google_cloud" {
  environment_name = var.environment_name
  google_org_id    = var.GOOGLE_ORG_ID
  project_id       = var.GOOGLE_PROJECT_ID
  redirect_uri     = var.automation_calculator_app_host
  source           = "../../../modules/google_cloud"
  support_email    = var.GOOGLE_SUPPORT_EMAIL
}
