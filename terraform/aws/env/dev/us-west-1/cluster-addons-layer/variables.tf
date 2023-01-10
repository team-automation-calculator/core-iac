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

variable "db_subnet_group_ids" {
  description = "The subnet group ids to grant access to the DB."
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster to deploy the cluster addons to."
  type        = string
}

variable "eks_cluster_oidc_provider_arn" {
  description = "The ARN of the EKS cluster OIDC provider."
  type        = string
}

variable "eks_cluster_launch_template_name" {
  description = "The name of the EKS cluster launch template."
  type        = string
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID to deploy the cluster addons to."
  type        = string
}
