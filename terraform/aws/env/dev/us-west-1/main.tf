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
  source           = "../../../modules/networking"
  environment_name = "dev"
}

module "automation_calculator_infra" {
  source           = "../../../modules/main_rails_app"
  environment_name = "dev"
  eks_subnet_ids   = module.networking_layer.eks_subnet_ids
}
