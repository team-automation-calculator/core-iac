output "enabled_apis" {
  description = "APIs this module keeps enabled on the project."
  value       = sort([for service in google_project_service.enabled : service.service])
}

output "project_id" {
  description = "The project ID."
  value       = google_project.this.project_id
}
