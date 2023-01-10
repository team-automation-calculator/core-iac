# Declare vars
variable "app_domain_name" {
  default     = "automation-calculations.io"
  description = "The domain name for the app."
  type        = string
}

variable "automation_calculator_app_host" {
  default     = "automation-calculations.io"
  description = "The host name of the automation-calculator-app"
  type        = string
}

variable "automation_calculator_helm_release_local_path" {
  default     = "helm-charts/automation-calculator"
  description = "The local path to the helm chart for the automation-calculator app."
  type        = string
}

variable "db_instance_class" {
  default     = "db.t4g.micro"
  description = "Amazon RDS instance type/class for the app database in this env."
  type        = string
}

variable "db_security_group_ids" {
  description = "The security group ids allowed access to the database."
  type        = list(string)
}

variable "db_subnet_group_ids" {
  description = "The ids for the subnet group to put the DB in, note this also chooses the VPC of the DB based on the subnet."
  type        = list(string)
}

variable "db_port" {
  default     = 5432
  description = "The port for the database."
  type        = number
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}
