terraform {
  required_version = ">= 1.5.7"

  required_providers {
    googleworkspace = {
      source  = "macadmins/googleworkspace"
      version = "~> 1.5"
    }
  }
}
