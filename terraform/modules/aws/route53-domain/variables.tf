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
