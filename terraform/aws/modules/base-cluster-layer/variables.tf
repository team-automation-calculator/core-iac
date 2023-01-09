variable "cluster_version" {
  default     = "1.24"
  description = "The AWS EKS version to use"
  type        = string
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "node_group_instance_types" {
  default     = ["t3.small"]
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

variable "tf_cloud_workspace_path" {
  description = "The path to the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  description = "The VCS repo identifier for the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "TF_VAR_GITHUB_TOKEN" {
  description = "Environment variable for the GitHub Personal Access Token to be used by Terraform Cloud to access the GitHub repository"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID of the VPC to put the app into"
  type        = string
}
