module "organization" {
  domain      = var.google_cloud_organization_domain
  iam_members = var.organization_iam_members
  source      = "../../../modules/google_cloud/organization"
}

module "project" {
  enabled_apis = var.enabled_apis
  folder_id    = var.google_cloud_folder_id
  labels       = var.labels
  # The project sits directly under the organization unless a folder is named.
  org_id       = var.google_cloud_folder_id == null ? module.organization.org_id : null
  project_id   = var.google_cloud_project_id
  project_name = var.google_cloud_project_name
  source       = "../../../modules/google_cloud/project"
}

# The project already exists (made by hand), so it is adopted into state
# rather than created. Import blocks must live in the root module. Once the
# first apply has run this block does nothing; it stays so that a rebuilt
# state adopts the project again.
#
# The organization has no import: Google creates it and the provider has no
# resource for it, so the module looks it up by domain.
import {
  to = module.project.google_project.this
  id = var.google_cloud_project_id
}
