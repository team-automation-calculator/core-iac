output "enabled_apis" {
  description = "APIs kept enabled on the project."
  value       = module.project.enabled_apis
}

output "service_account_ids" {
  description = "Account IDs of the service accounts managed in the project."
  value       = module.project.service_account_ids
}
