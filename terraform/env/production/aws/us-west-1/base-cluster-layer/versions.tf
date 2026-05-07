terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.47"
    }
  }
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "team-automation-calculator"

    workspaces {
      name = "ac_app_base_cluster_layer_production"
    }
  }
}
