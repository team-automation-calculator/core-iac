variable "aws_region" {
  default     = "us-east-1"
  description = "AWS region for the Route 53 Domains API (must be us-east-1)."
  type        = string
}

variable "environment_name" {
  description = "The application environment, i.e development/staging/production."
  type        = string
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project."
  type        = string
}

variable "domain_names" {
  description = "Set of domain names to register via Route 53."
  type        = set(string)
  default     = ["automation-calculations.net"]
}
