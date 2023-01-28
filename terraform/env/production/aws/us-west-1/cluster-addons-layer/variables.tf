variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "automation_calculator_app_host" {
  description = "The host name of the automation-calculator-app"
  type        = string
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}

variable "tf_cloud_organization_name" {
  default     = "team-automation-calculator"
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tfe_cluster_addons_layer_workspace_name" {
  default     = "core-iac"
  description = "The name of the Terraform Cloud workspace for the base layer."
  type        = string
}

variable "tf_cloud_workspace_path" {
  default     = "terraform/aws/env/production/us-west-1/cluster-addons-layer"
  description = "The path to the Terraform Cloud workspace."
  type        = string
}

variable "tfe_base_layer_workspace_name" {
  default     = "core-iac"
  description = "The name of the Terraform Cloud workspace for the base layer."
  type        = string
}