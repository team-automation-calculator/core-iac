variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster to install addons into."
  type        = string
}

variable "eks_cluster_api_endpoint" {
  description = "The api endpoint of the EKS cluster to install addons into."
  type        = string
}

variable "eks_cluster_cert_data" {
  description = "The cert data of the EKS cluster to install addons into."
  type        = string
}

variable "eks_cluster_oidc_provider_arn" {
  description = "The OIDC provider ARN of the EKS cluster to install addons into."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID of the VPC to put the app into"
  type        = string
}

variable "tfe_oauth_client_token_id" {
  description = "tfe_oauth_client token id used to connect terraform cloud workspaces to github repos"
  type        = string
  sensitive   = true
}

variable "tfe_organization_name" {
  default     = "team-automation-calculator"
  description = "The name of the Terraform Cloud organization."
  type        = string
}

variable "tf_cloud_workspace_path" {
  default     = "terraform/aws/env/development/us-west-1/cluster-addons-layer"
  description = "The path to the Terraform Cloud workspace."
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  description = "The VCS repo identifier for the Terraform Cloud workspace."
  type        = string
}
