# Declare vars
variable "project_tag" {
  type = string
  default = "automation-calculator"
}

variable "environment_name" {
  type = string
  default = "development"
}

variable "eks_subnet_ids" {
  type = list
  description = "Must be a list of length 2 of aws vpc subnet ids to give the eks cluster"
}
