terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.51.0"
    }
  }
}

#Note credentials are set using the GOOGLE_CREDENTIALS environment variable to enable consistent auth locally and on tf cloud
provider "google" {
  project = var.GOOGLE_PROJECT_ID
  region  = var.region
  zone    = var.zone
}
