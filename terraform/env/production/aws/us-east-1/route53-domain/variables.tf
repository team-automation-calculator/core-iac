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

variable "registrant_contact" {
  description = "WHOIS contact details for the domain registrant."
  type = object({
    first_name        = string
    last_name         = string
    contact_type      = string
    organization_name = string
    address_line_1    = string
    city              = string
    state             = string
    zip_code          = string
    country_code      = string
    email             = string
    phone_number      = string
  })
  sensitive = true
}
