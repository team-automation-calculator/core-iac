variable "domain_name" {
  description = "The domain name to register."
  type        = string
  default     = "automation-calculations.net"
}

variable "auto_renew" {
  description = "Whether the domain registration renews automatically."
  type        = bool
  default     = true
}

variable "transfer_lock_enabled" {
  description = "Whether the domain is locked from being transferred to another registrar."
  type        = bool
  default     = true
}

variable "privacy_protection" {
  description = "Whether to enable WHOIS privacy protection for all contacts."
  type        = bool
  default     = true
}

variable "enable_health_check" {
  description = "Whether to create a Route 53 health check for this domain."
  type        = bool
  default     = false
}

variable "health_check_path" {
  description = "Path to request for the health check."
  type        = string
  default     = "/"
}

variable "health_check_port" {
  description = "Port to use for the health check."
  type        = number
  default     = 443
}

variable "health_check_type" {
  description = "Protocol for the health check (HTTP, HTTPS, HTTP_STR_MATCH, HTTPS_STR_MATCH, TCP)."
  type        = string
  default     = "HTTPS"
}
