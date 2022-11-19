terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.38.0"
    }
  }
}

# Configure the AWS Provider
# Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables to authenticate
provider "aws" {
  region = "us-west-1"
  default_tags {
    tags = {
      Environment = "dev",
      Project     = "automation-calculator",
      SourceRepo  = "https://github.com/team-automation-calculator/core-iac"
    }
  }
}

module "networking_layer" {
  environment_name = "dev"
  source           = "../../../modules/networking"
}

module "automation_calculator_app_infra" {
  eks_service_ipv4_cidr = "10.100.0.0/16"
  eks_subnet_ids        = [module.networking_layer.public_eks_subnet_ids[0], module.networking_layer.private_eks_subnet_ids[1]]
  environment_name      = "dev"
  source                = "../../../modules/main_rails_app"
}
