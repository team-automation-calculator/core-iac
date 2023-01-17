terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.47"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "0.41.0"
    }
  }
}

# Configure the AWS Provider
# Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables to authenticate
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = var.environment_name,
      Project     = var.project_tag,
      SourceRepo  = "https://github.com/team-automation-calculator/core-iac"
    }
  }
}

provider "tfe" {
  hostname = "app.terraform.io"
}

resource "tfe_oauth_client" "github" {
  organization     = var.tf_cloud_organization_name
  api_url          = "https://api.github.com"
  http_url         = "https://github.com"
  service_provider = "github"
  oauth_token      = var.TF_VAR_GITHUB_TOKEN
}

module "eks_cluster" {
  environment_name                       = var.environment_name
  source                                 = "../../../../modules/base-cluster-layer"
  subnet_ids                             = module.networking_layer.private_eks_subnet_ids
  tfe_oauth_client_token_id              = tfe_oauth_client.github.oauth_token_id
  tf_cloud_organization_name             = var.tf_cloud_organization_name
  tf_cloud_workspace_path                = "terraform/aws/env/${var.environment_name}/${var.aws_region}/base-cluster-layer"
  tf_cloud_workspace_vcs_repo_identifier = var.tf_cloud_workspace_vcs_repo_identifier
  vpc_id                                 = module.networking_layer.vpc.id
}

module "networking_layer" {
  environment_name = var.environment_name
  source           = "../../../../modules/networking"
}
