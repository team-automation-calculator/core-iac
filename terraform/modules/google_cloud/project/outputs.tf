output "enabled_apis" {
  description = "APIs this module keeps enabled on the project."
  value       = sort([for service in google_project_service.enabled : service.service])
}

output "project_id" {
  description = "The project ID."
  value       = google_project.this.project_id
}

output "service_account_ids" {
  description = "Account IDs of the service accounts this module manages."
  value       = sort(keys(google_service_account.this))
}
