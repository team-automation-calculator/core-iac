output "domain_name" {
  description = "The registered domain name."
  value       = aws_route53domains_registered_domain.this.domain_name
}

output "expiration_date" {
  description = "The date when the domain registration expires."
  value       = aws_route53domains_registered_domain.this.expiration_date
}

output "registrar_name" {
  description = "Name of the registrar for this domain."
  value       = aws_route53domains_registered_domain.this.registrar_name
}

output "status_list" {
  description = "List of domain name status codes."
  value       = aws_route53domains_registered_domain.this.status_list
}

output "hosted_zone_id" {
  description = "The ID of the Route 53 hosted zone AWS created for the registered domain."
  value       = data.aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "Name servers in the delegation set for the hosted zone."
  value       = data.aws_route53_zone.this.name_servers
}

output "health_check_id" {
  description = "The ID of the Route 53 health check, or null if not enabled."
  value       = length(aws_route53_health_check.this) > 0 ? aws_route53_health_check.this[0].id : null
}
