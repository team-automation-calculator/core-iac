variable "auto_apply" {
  description = "When true, the base cluster and cluster add-ons workspaces apply a successful plan without a confirm. The other workspaces follow global_workspaces_auto_apply."
  type        = bool
  default     = false
}

variable "base_cluster_layer_module_directories" {
  default     = ["terraform/modules/aws/networking", "terraform/modules/aws/base-cluster-layer", "terraform/modules/aws/ci-iam-role", "terraform/modules/aws/sso-infra-eng"]
  description = "The list of module directories for the base cluster layer"
  type        = list(string)
}

variable "base_cluster_layer_working_directory" {
  default     = ""
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "cluster_addons_layer_module_directories" {
  default     = ["terraform/modules/aws/cluster-addons-layer", "terraform/modules/aws/main_rails_app", "terraform/modules/aws/argocd"]
  description = "The list of module directories for the cluster addons layer"
  type        = list(string)
}

variable "cluster_addons_layer_working_directory" {
  default     = ""
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "enable_cluster_addons_run_trigger" {
  description = "When true, creates a run trigger so that a successful apply in the base cluster workspace automatically queues a run in the cluster addons workspace."
  type        = bool
  default     = true
}

variable "enable_github_org_workspace" {
  description = "When true, creates a TFC workspace for the GitHub organization env config (CI machine user access)."
  type        = bool
  default     = false
}

variable "enable_google_cloud_workspace" {
  description = "When true, creates a TFC workspace for the Google Cloud env config (the project behind the Google service accounts)."
  type        = bool
  default     = false
}

variable "enable_google_workspace_workspace" {
  description = "When true, creates a TFC workspace for the Google Workspace env config (the group that gates the AWS Identity Center SAML app)."
  type        = bool
  default     = false
}

variable "enable_route53_domains_workspace" {
  description = "When true, creates a TFC workspace for the route53-domains env config."
  type        = bool
  default     = false
}

variable "environment_name" {
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "github_org_module_directories" {
  default     = ["terraform/modules/github/org-ci-access"]
  description = "Module directories that trigger a run in the GitHub organization workspace."
  type        = list(string)
}

variable "github_org_working_directory" {
  default     = ""
  description = "The path to the GitHub organization env config directory."
  type        = string
}

variable "global_workspaces_auto_apply" {
  default     = false
  description = "Auto-apply for the workspaces that exist once and have no staging counterpart to rehearse on: Route 53 domains, the GitHub organization, Google Workspace and Google Cloud. Kept apart from auto_apply so that turning it on for the cluster workspaces leaves these on a manual confirm."
  type        = bool
}

variable "google_cloud_module_directories" {
  default     = ["terraform/modules/google_cloud/organization", "terraform/modules/google_cloud/project"]
  description = "Module directories that trigger a run in the Google Cloud workspace."
  type        = list(string)
}

variable "google_cloud_working_directory" {
  default     = ""
  description = "The path to the Google Cloud env config directory."
  type        = string
}

variable "google_workspace_module_directories" {
  default     = ["terraform/modules/google_workspace/aws-identity-center-access"]
  description = "Module directories that trigger a run in the Google Workspace workspace."
  type        = list(string)
}

variable "google_workspace_working_directory" {
  default     = ""
  description = "The path to the Google Workspace env config directory."
  type        = string
}

variable "route53_domains_module_directories" {
  description = "Module directories that trigger a run in the route53-domains workspace."
  type        = list(string)
  default     = ["terraform/modules/aws/route53-domain"]
}

variable "route53_domains_working_directory" {
  description = "The path to the route53-domains env config directory."
  type        = string
  default     = ""
}

variable "trigger_on_shared_code" {
  default     = true
  description = "When true, a change to the shared module directories triggers the base cluster and cluster add-ons workspaces. When false, only this environment's own working directories do, so shared changes reach it with the next pull request that changes a file in one of those (docs/promotion.md). The app chart triggers neither: ArgoCD deploys it."
  type        = bool
}

variable "tf_cloud_organization_name" {
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  description = "The VCS repo identifier for the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "tfe_oauth_client_token_id" {
  description = "tfe_oauth_client token id used to connect terraform cloud workspaces to github repos"
  type        = string
  sensitive   = true
}

variable "tfe_workspace_tf_version" {
  description = "Allows for version pinning of tfe workspaces that have been created, because otherwise TF Cloud just chooses the latest one."
  type        = string
  default     = "1.17"
}
