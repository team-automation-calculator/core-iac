terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "team-automation-calculator"

    workspaces {
      name = "ac_app_production_google_cloud"
    }
  }
}
