# admin.googleapis.com is the Admin SDK API the Google Workspace workspace
# calls. iam.googleapis.com is what the provider calls to read the service
# accounts. The other three are what it calls to read the project, its billing
# link and its enabled APIs.
enabled_apis = [
  "admin.googleapis.com",
  "cloudbilling.googleapis.com",
  "cloudresourcemanager.googleapis.com",
  "iam.googleapis.com",
  "serviceusage.googleapis.com",
]

# Both accounts were made by hand on 2026-11-19 and are imported. Their keys
# stay hand-made (docs/google-cloud-terraform.md).
service_accounts = {
  terraform-google-cloud = {
    description     = "Terraform Cloud workspace ac_app_production_google_cloud runs as this account. Managed by Terraform in core-iac."
    import_existing = true
    # Do not remove roles/owner: it is what lets this workspace manage the
    # project, including this grant.
    project_roles = ["roles/owner"]
  }
  terraform-google-workspace = {
    description     = "Terraform Cloud workspace ac_app_production_google_workspace runs as this account. It holds Groups Admin in Google Workspace and needs no Google Cloud roles. Managed by Terraform in core-iac."
    import_existing = true
  }
}
