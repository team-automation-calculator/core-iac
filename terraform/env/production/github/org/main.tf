module "org_ci_access" {
  ci_github_username     = var.ci_github_username
  repository_permissions = var.repository_permissions
  source                 = "../../../../modules/github/org-ci-access"
}
