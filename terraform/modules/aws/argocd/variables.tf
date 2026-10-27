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
