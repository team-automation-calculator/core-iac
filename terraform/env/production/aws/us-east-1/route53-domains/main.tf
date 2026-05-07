module "route53_domains" {
  for_each           = var.domain_names
  source             = "../../../../../modules/aws/route53-domain"
  domain_name        = each.key
  privacy_protection = true
}
