variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "argocd_application_automated_sync" {
  default     = false
  description = "Render syncPolicy.automated on the app's ArgoCD Application (docs/argocd-migration-plan.md, Phase 6). Only after this env's workspace has forgotten the Helm release (manage_app_helm_release = false, applied) and its Helm history is deleted: until then two controllers would reconcile the same Deployment. Runbook: docs/argocd-phase-6-retire-staging-release.md."
  type        = bool
}

variable "argocd_application_prune" {
  default     = false
  description = "syncPolicy.automated.prune on the app's ArgoCD Application. Read only with argocd_application_automated_sync. Safe once `argocd app resources` lists only the Service, Deployment and Ingress (the Terraform-managed Secret carries no ArgoCD tracking annotation)."
  type        = bool
}

variable "argocd_application_self_heal" {
  default     = false
  description = "syncPolicy.automated.selfHeal on the app's ArgoCD Application. Read only with argocd_application_automated_sync."
  type        = bool
}

variable "argocd_enabled" {
  default     = false
  description = "Set to true to install ArgoCD into this environment's cluster (docs/argocd-migration-plan.md, Phase 2)."
  type        = bool
}

variable "argocd_manage_application" {
  default     = true
  description = "With argocd_enabled, also create the app's ArgoCD AppProject and Application (docs/argocd-migration-plan.md, Phase 5). Set to false to roll the Application back while keeping ArgoCD installed; the Application carries no finalizer, so its deletion never touches the app's objects."
  type        = bool
}

variable "app_repo_url" {
  default     = "https://github.com/team-automation-calculator/core-iac.git"
  description = "Git URL of this repository: the ArgoCD Application's source and the only source its AppProject allows (docs/argocd-migration-plan.md, Phase 5)."
  type        = string
}

variable "automation_calculator_app_host" {
  default     = "automation-calculations.io"
  description = "The host name of the automation-calculator-app"
  type        = string
}

variable "aws_region" {
  default     = "us-west-1"
  description = "AWS Region to deploy the stack to, i.e us-west-1, us-east-1, etc"
  type        = string
}

variable "db_engine_version" {
  description = "The PostgreSQL engine version for the RDS instance."
  type        = string
}

variable "external_dns_txt_prefix" {
  default     = ""
  description = "external-dns TXT registry prefix; empty leaves it unset. Set only after pre-creating the new-format TXT records, see docs/external-dns-txt-prefix-migration.md."
  type        = string
}

variable "github_oauth_app_id" {
  description = "The GitHub OAuth App ID for the automation-calculator app."
  type        = string
}

variable "github_oauth_app_secret" {
  description = "The GitHub OAuth App Secret for the automation-calculator app."
  type        = string
}

variable "google_oauth_app_id" {
  description = "The Google OAuth App ID for the automation-calculator app."
  type        = string
}

variable "google_oauth_app_secret" {
  description = "The Google OAuth App Secret for the automation-calculator app."
  type        = string
}

variable "manage_app_helm_release" {
  default     = true
  description = "Manage the app's Helm release from this workspace (module.main_rails_app.helm_release.automation-calculator[0]). ArgoCD migration Phase 6: set to false only AFTER `terraform state rm` of that release in this workspace; flipping it first plans a destroy, which prevent_destroy on the release turns into a plan error. Runbook: docs/argocd-phase-6-retire-staging-release.md."
  type        = bool
}

variable "project_tag" {
  default     = "automation_calculator"
  description = "Tag for describing the name of the project, i.e automation-calculator"
  type        = string
}

variable "tf_cloud_organization_name" {
  default     = "team-automation-calculator"
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tf_cloud_workspace_path" {
  default     = "terraform/aws/env/development/us-west-1/cluster-addons-layer"
  description = "The path to the Terraform Cloud workspace."
  type        = string
}

variable "tfe_base_layer_workspace_name" {
  description = "The name of the Terraform Cloud workspace for the base layer."
  type        = string
}
