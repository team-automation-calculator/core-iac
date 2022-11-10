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
      Project     = "automation-calculator",
      Environment = "dev"
    }
  }
}

module "networking-layer" {
  source     = "../../../modules/networking"
  cidr_block = "10.0.0.0/24"
  environment_name = "dev"
}

module "automation-calculator-infra" {
  source           = "../../../modules/main-rails-app"
  environment_name = "dev"
}
