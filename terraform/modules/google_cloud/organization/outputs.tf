output "domain" {
  description = "Domain the organization was looked up by."
  value       = data.google_organization.this.domain
}

output "org_id" {
  description = "Numeric ID of the organization."
  value       = data.google_organization.this.org_id
}
