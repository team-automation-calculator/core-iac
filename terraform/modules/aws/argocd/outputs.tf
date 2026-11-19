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
