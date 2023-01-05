terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.4.0"
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

data "aws_eks_cluster" "target_cluster" {
  name = module.eks_cluster.eks_cluster_name
}

data "aws_eks_cluster_auth" "target_cluster_auth" {
  name = module.eks_cluster.eks_cluster_name
}

# Configure the helm provider with the EKS cluster auth variables
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.target_cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.target_cluster.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.target_cluster_auth.token
  }
}

module "automation_calculator_app_infra" {
  automation_calculator_helm_release_local_path = "../../../../helm/automation-calculator"
  environment_name                              = var.environment_name
  source                                        = "../../../modules/main_rails_app"
}

module "eks_cluster" {
  environment_name = var.environment_name
  source           = "../../../modules/eks_cluster"
  subnet_ids       = module.networking_layer.private_eks_subnet_ids
  vpc_id           = module.networking_layer.vpc.id
}

module "networking_layer" {
  environment_name = "dev"
  source           = "../../../modules/networking"
}
