provider "tfe" {
  hostname = "app.terraform.io"
  # Null in normal operation: the provider then reads the TFE_TOKEN environment
  # variable. Set only for the one bootstrap run (docs/tfc-org-members.md).
  token = var.tfc_bootstrap_token
}
