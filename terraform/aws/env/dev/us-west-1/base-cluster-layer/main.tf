terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.47"
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

module "eks_cluster" {
  environment_name = var.environment_name
  source           = "../../../../modules/base-cluster-layer"
  subnet_ids       = module.networking_layer.private_eks_subnet_ids
  vpc_id           = module.networking_layer.vpc.id
}

module "networking_layer" {
  environment_name = var.environment_name
  source           = "../../../../modules/networking"
}
