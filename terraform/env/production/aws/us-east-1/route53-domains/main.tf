module "route53_domains" {
  for_each            = var.domain_names
  source              = "../../../../../modules/aws/route53-domain"
  domain_name         = each.key
  privacy_protection  = true
  enable_health_check = each.value.enable_health_check
  health_check_path   = each.value.health_check_path
  health_check_port   = each.value.health_check_port
  health_check_type   = each.value.health_check_type
}
