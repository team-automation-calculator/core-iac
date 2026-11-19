terraform {
  required_providers {
    googleworkspace = {
      source  = "macadmins/googleworkspace"
      version = "~> 1.5"
    }
  }
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "team-automation-calculator"

    workspaces {
      name = "ac_app_production_google_workspace"
    }
  }
}
