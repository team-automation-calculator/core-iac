output "argocd_chart_version" {
  description = "The argo-cd chart version that was installed."
  value       = helm_release.argocd.version
}

output "argocd_namespace" {
  description = "The namespace ArgoCD was installed into."
  value       = helm_release.argocd.namespace
}

output "argocd_release_name" {
  description = "The Helm release name of the ArgoCD installation."
  value       = helm_release.argocd.name
}

output "argocd_apps_chart_version" {
  description = "The argocd-apps chart version that renders the AppProject and Application; null when manage_application is false."
  value       = one(helm_release.argocd_apps[*].version)
}

output "application_name" {
  description = "Name of the app's ArgoCD Application (and AppProject, and Helm release name inside the Application); null when manage_application is false."
  value       = var.manage_application ? local.app_name : null
}
