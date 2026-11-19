# Authenticates as a GCP service account that holds the Groups Admin role in
# Google Workspace directly (no domain-wide delegation, no impersonated user).
# Its key is never set locally: the JSON contents live in the sensitive
# GOOGLEWORKSPACE_CREDENTIALS environment variable on the Terraform Cloud
# workspace. Bootstrap steps: docs/google-workspace-terraform.md.
provider "googleworkspace" {
  customer_id  = var.google_workspace_customer_id
  oauth_scopes = ["https://www.googleapis.com/auth/admin.directory.group"]
}
