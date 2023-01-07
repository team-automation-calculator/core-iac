variable "alb_controller_irsa_role_arn" {
  description = "The ARN of the IAM role to use for the AWS Load Balancer Controller service account."
  type        = string
}

variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster to deploy the cluster addons to."
  type        = string
}

variable "eks_cluster_api_endpoint" {
  description = "The endpoint of the EKS cluster to deploy the cluster addons to."
  type        = string
}

variable "eks_cluster_cert_data" {
  description = "The certificate data of the EKS cluster to deploy the cluster addons to, will be base64 decoded"
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
