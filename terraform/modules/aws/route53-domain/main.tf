resource "aws_route53domains_registered_domain" "this" {
  domain_name   = var.domain_name
  auto_renew    = var.auto_renew
  transfer_lock = var.transfer_lock_enabled

  admin_privacy      = var.privacy_protection
  registrant_privacy = var.privacy_protection
  tech_privacy       = var.privacy_protection

  tags = {
    Project = "automation_calculator"
  }
}

data "aws_route53_zone" "this" {
  name         = aws_route53domains_registered_domain.this.domain_name
  private_zone = false
}

resource "aws_route53_health_check" "this" {
  count = var.enable_health_check ? 1 : 0

  fqdn              = var.domain_name
  port              = var.health_check_port
  type              = var.health_check_type
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Project = "automation_calculator"
  }
}
