variable "ami_type" {
  default     = "AL2023_x86_64"
  description = "The AMI type to use for the EKS node group."
  type        = string
}

variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "ci_read_only_trusted_principal_arns" {
  default     = []
  description = "IAM principal ARNs allowed to assume the read-only CI Terraform role. When empty, no principal can assume it."
  type        = list(string)
}

variable "ci_trusted_principal_arns" {
  default     = []
  description = "IAM principal ARNs (CI users/roles) allowed to assume the CI Terraform role. When empty, no principal can assume it."
  type        = list(string)
}

variable "enable_sso_infra_eng" {
  default     = false
  description = "Create the IAM Identity Center InfraEng permission set and account assignment for this environment. Enable only after the Identity Center instance exists and the Google Workspace identity provider is connected."
  type        = bool
}

variable "environment_name" {
  description = "The application production environment, i.e development/staging/production."
  type        = string
}

variable "kubernetes_cluster_version" {
  description = "The kubernetes cluster version"
  type        = string
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}
