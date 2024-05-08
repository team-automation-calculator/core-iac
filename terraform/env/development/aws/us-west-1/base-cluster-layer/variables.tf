variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "environment_name" {
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "kubernetes_cluster_version" {
  description = "The kubernetes cluster version"
  type        = string
  default     = "1.24"
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}
