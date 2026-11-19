# admin.googleapis.com is the Admin SDK API the Google Workspace workspace
# calls. iam.googleapis.com is what the provider calls to read the service
# account. The other three are what it calls to read the project, its billing
# link and its enabled APIs.
enabled_apis = [
  "admin.googleapis.com",
  "cloudbilling.googleapis.com",
  "cloudresourcemanager.googleapis.com",
  "iam.googleapis.com",
  "serviceusage.googleapis.com",
]

# The project's one service account, made by hand on 2026-11-19 and imported.
# Both Terraform Cloud workspaces hold a key for it; the keys stay hand-made
# (docs/google-cloud-terraform.md).
service_accounts = {
  terraform-google-workspace = {
    description     = "Terraform Cloud runs as this account: ac_app_production_google_workspace (Groups Admin in Google Workspace) and ac_app_production_google_cloud (Owner on this project). Managed by Terraform in core-iac."
    import_existing = true
    # Do not remove roles/owner: it is what lets the google_cloud workspace
    # manage the project, including this grant.
    project_roles = ["roles/owner"]
  }
}
