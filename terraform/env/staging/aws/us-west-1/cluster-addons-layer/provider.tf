provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = data.tfe_outputs.base_layer_state.nonsensitive_values.environment_name,
      Project     = var.project_tag,
      SourceRepo  = "https://github.com/team-automation-calculator/core-iac"
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.target_cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.target_cluster.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.target_cluster_auth.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.target_cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.target_cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.target_cluster_auth.token
}
