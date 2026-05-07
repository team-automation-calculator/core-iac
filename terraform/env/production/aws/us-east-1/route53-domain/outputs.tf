output "domain_name" {
  description = "The registered domain name."
  value       = module.route53_domain.domain_name
}

output "hosted_zone_id" {
  description = "The Route 53 hosted zone ID for the registered domain."
  value       = module.route53_domain.hosted_zone_id
}

output "name_servers" {
  description = "The name servers for the domain's hosted zone."
  value       = module.route53_domain.name_servers
}

output "expiration_date" {
  description = "The date when the domain registration expires."
  value       = module.route53_domain.expiration_date
}
