terraform {
  # The import blocks in main.tf use for_each, which needs Terraform 1.7. The
  # workspace that runs this config is hand-made, so its Terraform version is
  # set in the TFC UI, not by tfe_workspace_tf_version.
  required_version = ">= 1.7"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.82"
    }
  }
}
