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
  description = "Map of domain names to per-domain configuration."
  type = map(object({
    enable_health_check = optional(bool, false)
    health_check_path   = optional(string, "/")
    health_check_port   = optional(number, 443)
    health_check_type   = optional(string, "HTTPS")
  }))
  default = {
    "automation-calculations.net" = {}
  }
}
