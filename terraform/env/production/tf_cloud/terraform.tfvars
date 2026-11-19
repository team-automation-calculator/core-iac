base_cluster_layer_working_directory   = "terraform/env/production/aws/us-west-1/base-cluster-layer"
cluster_addons_layer_working_directory = "terraform/env/production/aws/us-west-1/cluster-addons-layer"
enable_github_org_workspace            = true
enable_google_workspace_workspace      = true
enable_route53_domains_workspace       = true
environment_name                       = "production"
github_org_working_directory           = "terraform/env/production/github/org"
google_workspace_working_directory     = "terraform/env/production/google_workspace"
route53_domains_working_directory      = "terraform/env/production/aws/us-east-1/route53-domains"
tfc_organization_members = {
  steven_uray = {
    email           = "steven.uray@automation-calculations.net"
    import_existing = true
    owner           = true
  }
}
tfc_owner_token_expired_at = "2027-11-18T00:00:00Z"
tfe_workspace_tf_version   = "1.17"
