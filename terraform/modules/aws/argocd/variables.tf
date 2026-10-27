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

# The admin password is managed as a bcrypt HASH, never as plaintext and never
# hashed in HCL: Terraform's bcrypt() salts differently on every call, so a
# hash computed here would upgrade ArgoCD on every run. Generate the hash once
# on a laptop (`argocd account bcrypt --password '<pw>'`), keep the plaintext in
# the team password manager, and store only the hash as a sensitive TFC
# workspace variable. When unset, the chart falls back to generating a random
# password into argocd-initial-admin-secret (docs/argocd-phase-2-install.md).
variable "argocd_admin_password_bcrypt_hash" {
  default     = null
  description = "bcrypt hash of the ArgoCD admin password, written to admin.password in the argocd-secret Secret. null leaves password generation to the chart."
  nullable    = true
  sensitive   = true
  type        = string

  validation {
    condition     = var.argocd_admin_password_bcrypt_hash == null || can(regex("^\\$2[ab]\\$[0-9]{2}\\$.{53}$", var.argocd_admin_password_bcrypt_hash))
    error_message = "argocd_admin_password_bcrypt_hash must be a bcrypt hash ($2a$ or $2b$, 60 characters), not a plaintext password. Generate it with `argocd account bcrypt --password '<pw>'`."
  }
}

variable "argocd_admin_password_mtime" {
  default     = null
  description = "RFC 3339 UTC timestamp (e.g. 2026-10-26T18:00:00Z) of the last admin password change, written to admin.passwordMtime. Sessions issued before it are invalidated. Required whenever the hash is set, otherwise the chart stamps the render time and every upgrade logs everyone out."
  nullable    = true
  type        = string

  validation {
    condition     = (var.argocd_admin_password_bcrypt_hash == null) == (var.argocd_admin_password_mtime == null)
    error_message = "argocd_admin_password_bcrypt_hash and argocd_admin_password_mtime must be set together (both null, or both set)."
  }

  validation {
    condition     = var.argocd_admin_password_mtime == null || can(formatdate("YYYY-MM-DD", var.argocd_admin_password_mtime))
    error_message = "argocd_admin_password_mtime must be an RFC 3339 timestamp such as 2026-10-26T18:00:00Z."
  }
}
