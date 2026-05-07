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

# Contact object type used for registrant, admin, and tech contacts.
# Pass organization_name = "" when contact_type is PERSON.
# phone_number format: +[country code].[subscriber number], e.g. "+1.5555551234".
variable "registrant_contact" {
  description = "Contact details for the domain registrant."
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
}

variable "admin_contact" {
  description = "Contact details for the domain admin. Defaults to registrant_contact when null."
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
  default = null
}

variable "tech_contact" {
  description = "Contact details for the domain technical contact. Defaults to registrant_contact when null."
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
  default = null
}
