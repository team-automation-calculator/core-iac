module "route53_domain" {
  source             = "../../../../../modules/aws/route53-domain"
  privacy_protection = true
  registrant_contact = var.registrant_contact
}
