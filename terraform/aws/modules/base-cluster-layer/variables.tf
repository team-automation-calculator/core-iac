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

variable "tf_cloud_organization_name" {
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tf_cloud_workspace_path" {
  description = "The path to the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  description = "The VCS repo identifier for the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "tfe_oauth_client_token" {
  description = "tfe_oauth_client token used to connect terraform cloud workspaces to github repos"
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  description = "VPC ID of the VPC to put the app into"
  type        = string
}
