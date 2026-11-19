output "argocd_admin_password" {
  description = "The generated ArgoCD admin password, null while argocd_enabled is false. Sensitive: reveal it in the workspace Outputs tab or with terraform output (docs/argocd-phase-2-install.md, section 4)."
  sensitive   = true
  value       = one(module.argocd[*].argocd_admin_password)
}

output "argocd_admin_password_mtime" {
  description = "RFC 3339 time the current ArgoCD admin password was generated, null while argocd_enabled is false."
  value       = one(module.argocd[*].argocd_admin_password_mtime)
}
