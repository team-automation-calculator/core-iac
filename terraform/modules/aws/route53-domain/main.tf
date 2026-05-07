locals {
  admin_contact = var.admin_contact != null ? var.admin_contact : var.registrant_contact
  tech_contact  = var.tech_contact != null ? var.tech_contact : var.registrant_contact
}

resource "aws_route53domains_registered_domain" "this" {
  domain_name           = var.domain_name
  auto_renew            = var.auto_renew
  transfer_lock_enabled = var.transfer_lock_enabled

  privacy_protect_admin_contact      = var.privacy_protection
  privacy_protect_registrant_contact = var.privacy_protection
  privacy_protect_tech_contact       = var.privacy_protection

  registrant_contact {
    first_name        = var.registrant_contact.first_name
    last_name         = var.registrant_contact.last_name
    contact_type      = var.registrant_contact.contact_type
    organization_name = var.registrant_contact.organization_name
    address_line_1    = var.registrant_contact.address_line_1
    city              = var.registrant_contact.city
    state             = var.registrant_contact.state
    zip_code          = var.registrant_contact.zip_code
    country_code      = var.registrant_contact.country_code
    email             = var.registrant_contact.email
    phone_number      = var.registrant_contact.phone_number
  }

  admin_contact {
    first_name        = local.admin_contact.first_name
    last_name         = local.admin_contact.last_name
    contact_type      = local.admin_contact.contact_type
    organization_name = local.admin_contact.organization_name
    address_line_1    = local.admin_contact.address_line_1
    city              = local.admin_contact.city
    state             = local.admin_contact.state
    zip_code          = local.admin_contact.zip_code
    country_code      = local.admin_contact.country_code
    email             = local.admin_contact.email
    phone_number      = local.admin_contact.phone_number
  }

  tech_contact {
    first_name        = local.tech_contact.first_name
    last_name         = local.tech_contact.last_name
    contact_type      = local.tech_contact.contact_type
    organization_name = local.tech_contact.organization_name
    address_line_1    = local.tech_contact.address_line_1
    city              = local.tech_contact.city
    state             = local.tech_contact.state
    zip_code          = local.tech_contact.zip_code
    country_code      = local.tech_contact.country_code
    email             = local.tech_contact.email
    phone_number      = local.tech_contact.phone_number
  }

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_route53_zone" "this" {
  name         = aws_route53domains_registered_domain.this.domain_name
  private_zone = false
}
