# Declare vars
variable "app_domain_name" {
  default     = "automation-calculations.io"
  description = "The domain name for the app."
  type        = string
}

variable "database_instance_class" {
  default     = "db.t4g.micro"
  description = "Amazon RDS instance type/class for the app database in this env."
  type        = string
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}
