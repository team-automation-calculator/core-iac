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
  region = var.aws_region
  default_tags {
    tags = {
      Environment = var.environment_name,
      Project     = var.project_tag,
      SourceRepo  = "https://github.com/team-automation-calculator/core-iac"
    }
  }
}

module "automation_calculator_app_infra" {
  environment_name = var.environment_name
  source           = "../../../modules/main_rails_app"
}

module "eks_cluster" {
  environment_name  = var.environment_name
  service_ipv4_cidr = "172.20.0.0/16"
  source            = "../../../modules/eks_cluster"
  subnet_ids        = concat(module.networking_layer.public_eks_subnet_ids, module.networking_layer.private_eks_subnet_ids)
  vpc_id            = module.networking_layer.vpc.id
}

module "networking_layer" {
  environment_name = "dev"
  source           = "../../../modules/networking"
}
