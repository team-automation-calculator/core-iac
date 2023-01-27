variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "automation_calculator_app_host" {
  default     = "automation-calculations.io"
  description = "The host name of the automation-calculator-app"
  type        = string
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}

variable "tfe_cluster_addons_layer_workspace_name" {
  default     = "core-iac"
  description = "The name of the Terraform Cloud workspace for the base layer."
  type        = string
}

variable "tf_cloud_workspace_path" {
  default     = "terraform/aws/env/development/us-west-1/cluster-addons-layer"
  description = "The path to the Terraform Cloud workspace."
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  default     = "team-automation-calculator/core-iac"
  description = "The identifier of the VCS repository for the Terraform Cloud workspace."
  type        = string
}

variable "tfe_base_layer_workspace_name" {
  default     = "ac_app_base_cluster_layer_development"
  description = "The name of the Terraform Cloud workspace for the base layer."
  type        = string
}

variable "tfe_organization_name" {
  default     = "team-automation-calculator"
  description = "The name of the Terraform Cloud organization."
  type        = string
}

variable "TF_VAR_GITHUB_TOKEN" {
  description = "Environment variable for the GitHub Personal Access Token to be used by Terraform Cloud to access the GitHub repository"
  type        = string
  sensitive   = true
}
