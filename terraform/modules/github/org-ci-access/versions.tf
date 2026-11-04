terraform {
  required_version = ">= 1.5.7"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}
