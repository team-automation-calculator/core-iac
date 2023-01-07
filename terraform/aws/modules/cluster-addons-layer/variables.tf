variable alb_controller_irsa_role_arn {
  description = "The ARN of the IAM role to use for the AWS Load Balancer Controller service account."
  type        = string
}

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

variable "vpc_id" {
  description = "VPC ID of the VPC to put the app into"
  type        = string
}
