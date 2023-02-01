resource "google_project" "env_project" {
  name       = "ac-app-${var.environment_name}"
  org_id     = var.google_org_id
  project_id = var.project_id
}

resource "google_project_service" "env_project_service" {
  project = google_project.env_project.project_id
  service = "iap.googleapis.com"
}

resource "google_iap_brand" "env_project_brand" {
  support_email     = var.support_email
  application_title = var.application_title
  project           = google_project_service.env_project_service.project
}

resource "google_iap_client" "env_project_client" {
  display_name = var.display_name
  brand        = google_iap_brand.env_project_brand.name
}
