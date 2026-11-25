# Authenticates with the GITHUB_TOKEN environment variable, which is set as a
# sensitive environment variable on the Terraform Cloud workspace. The token
# must belong to an organization owner (see docs/github-ci-user.md).
provider "github" {
  owner = var.github_organization
}
