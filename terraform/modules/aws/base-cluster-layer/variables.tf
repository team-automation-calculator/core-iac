variable "access_entries" {
  default     = {}
  description = "EKS access entries granting IAM principals access to the cluster API, passed through to the EKS module. Map of entries keyed by a static name, each with principal_arn and optional policy_associations."
  type        = any
}

variable "ami_id" {
  default     = null
  description = "The custom AMI ID to use for the EKS node group. If set, this will override the AMI type."
  type        = string
}

variable "ami_type" {
  default     = "AL2023_x86_64"
  description = "The AMI type to use for the EKS node group."
  type        = string
}

variable "cluster_version" {
  default     = "1.26"
  description = "The AWS EKS version to use"
  type        = string
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "node_group_instance_types" {
  default     = ["t3.medium"]
  description = "The AWS EC2 instance types to use to create worker nodes with"
  type        = list(string)
}

variable "node_group_scaling_config" {
  default = {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }
  description = "The scaling config for the EKS node group for the application EKS cluster."
  type = object({
    desired_size = number
    max_size     = number
    min_size     = number
  })
}

variable "subnet_ids" {
  description = "A list of subnet IDs in the provided VPC for the cluster to use"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID of the VPC to put the app into"
  type        = string
}
