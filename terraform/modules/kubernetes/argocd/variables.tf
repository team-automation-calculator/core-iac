# Pinned in docs/argocd-migration-plan.md (Phase 0 "Versions"). Re-pin only in
# a deliberate upgrade PR, together with that table.
variable "argocd_chart_version" {
  default     = "10.11.6"
  description = "Version of the argo-cd chart from https://argoproj.github.io/argo-helm to install (10.11.6 ships Argo CD v3.5.6)."
  type        = string
}

variable "argocd_namespace" {
  default     = "argocd"
  description = "Namespace to install ArgoCD into. Created by the release."
  type        = string
}

# --- Phase 5: the app's AppProject and Application (helm_release.argocd_apps) ---

variable "app_certificate_arn" {
  description = "ACM certificate ARN for the app's Ingress, injected into the Application as the ingress.certificateArn Helm parameter. The output automation_calculator_app_certificate_arn of the main_rails_app module. Must never be written into the chart's values files: this repository is public."
  type        = string

  validation {
    condition     = !var.manage_application || can(regex("^arn:aws:acm:", var.app_certificate_arn))
    error_message = "app_certificate_arn must be an ACM certificate ARN (arn:aws:acm:...) when manage_application is true."
  }
}

variable "app_chart_path" {
  default     = "helm/automation-calculator"
  description = "Path of the app's Helm chart inside app_repo_url."
  type        = string
}

variable "app_namespace" {
  default     = "automation-calculator"
  description = "Namespace the Application deploys into and the only destination the AppProject allows. Must match the namespace of Terraform's main_rails_app release and Secret."
  type        = string
}

variable "app_repo_url" {
  description = "Git URL of the repository holding the app chart (this repository), the only source the AppProject allows."
  type        = string
}

variable "app_target_revision" {
  default     = "main"
  description = "Git revision (branch, tag or SHA) the Application tracks."
  type        = string
}

variable "application_automated_sync" {
  default     = false
  description = "Render syncPolicy.automated on the Application. Keep false while Terraform still manages the app's Helm release (Phase 5): two controllers must never reconcile the same Deployment. Phase 6 flips it per env after `terraform state rm`."
  type        = bool
}

variable "application_prune" {
  default     = false
  description = "syncPolicy.automated.prune. Only read when application_automated_sync is true."
  type        = bool
}

variable "application_self_heal" {
  default     = false
  description = "syncPolicy.automated.selfHeal. Only read when application_automated_sync is true."
  type        = bool
}

# Pinned in docs/argocd-migration-plan.md (Phase 0 "Versions"). Re-pin only in
# a deliberate upgrade PR, together with that table.
variable "argocd_apps_chart_version" {
  default     = "2.0.7"
  description = "Version of the argocd-apps chart from https://argoproj.github.io/argo-helm that renders the AppProject and Application (CR manifests only, no controller)."
  type        = string
}

variable "environment_name" {
  description = "The environment (development/staging/production). Selects the chart's values-<environment_name>.yaml for the Application."
  type        = string
}

variable "manage_application" {
  default     = true
  description = "Create the app's AppProject and Application (helm_release.argocd_apps) alongside the ArgoCD install. Default true so an env that enables ArgoCD gets the Application in the same apply (Phase 8 production). Set false to install ArgoCD alone."
  type        = bool
}
