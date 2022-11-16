# Declare vars
variable "database_instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "Amazon RDS instance type/class for the app database in this env"
}

variable "environment_name" {
  type    = string
  default = "development"
}

variable "eks_subnet_ids" {
  type        = list(any)
  description = "Must be a list of length 2 of aws vpc subnet ids to give the eks cluster"
}

variable "project_tag" {
  type    = string
  default = "automation-calculator"
}
