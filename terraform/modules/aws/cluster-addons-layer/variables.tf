variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "cloudwatch_alarms_enabled" {
  description = "Set to true to create the CloudWatch alarms and SNS alerting resources. Requires the app ALB to exist, so must be false on initial bootstrap."
  type        = bool
  default     = false
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
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

variable "eks_cluster_name" {
  description = "The name of the EKS cluster to install addons into."
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
