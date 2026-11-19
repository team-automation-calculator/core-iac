# Authenticates as a GCP service account with access to this one project. Its
# key is never set locally: the JSON contents live in the sensitive
# GOOGLE_CREDENTIALS environment variable on the Terraform Cloud workspace.
# Bootstrap steps: docs/google-cloud-terraform.md.
provider "google" {
  project = var.google_cloud_project_id
}
