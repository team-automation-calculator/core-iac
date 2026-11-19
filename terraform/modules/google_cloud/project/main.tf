# The Google Cloud project that holds the service accounts Terraform uses to
# reach Google (docs/google-cloud-terraform.md). The project was made by hand
# and is imported by the env config, never created here.
resource "google_project" "this" {
  auto_create_network = var.auto_create_network
  deletion_policy     = "PREVENT"
  folder_id           = var.folder_id
  labels              = var.labels
  name                = var.project_name
  org_id              = var.org_id
  project_id          = var.project_id

  lifecycle {
    # Billing is linked by hand. billing_account is not computed in the
    # provider, so leaving it unset would otherwise plan to unlink billing
    # from the imported project, and setting it would put the billing account
    # id in a public repo.
    ignore_changes  = [billing_account]
    prevent_destroy = true
  }
}

# Enabling an API that is already on is a no-op, so these need no import.
# disable_on_destroy is false: taking an API off the list stops managing it
# and leaves it enabled. Turn it off by hand if that is what you want.
resource "google_project_service" "enabled" {
  for_each = var.enabled_apis

  disable_on_destroy = false
  project            = google_project.this.project_id
  service            = each.value
}
