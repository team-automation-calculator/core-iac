variable "eks_node_group_instance_types" {
  default     = ["t3.micro"]
  description = "The AWS EC2 instance types to use to create worker nodes with"
  type        = list(string)
}

variable "eks_node_group_max_unavailable" {
  default     = 1
  description = "The maximum number of eks worker group nodes unavailable at a given time due to scaling events."
  type        = number
}

variable "eks_node_group_scaling_config" {
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

variable "eks_service_ipv4_cidr" {
  description = "The ipv4 cidr block to assign k8s resources ips from."
  type        = string
}

variable "eks_subnet_ids" {
  description = "Must be a list of length 2 of aws vpc subnet ids to give the eks cluster."
  type        = list(any)
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}
