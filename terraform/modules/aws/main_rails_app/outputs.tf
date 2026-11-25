output "automation_calculator_app_certificate_arn" {
  description = "ARN of the ACM certificate for the app host and its www. alias. Injected into the ArgoCD Application as the ingress.certificateArn parameter (terraform/modules/kubernetes/argocd); it is the only value Terraform passes to the app chart since ArgoCD migration Phase 9 retired the Helm release that used to carry it."
  value       = aws_acm_certificate.automation_calculator_app.arn
}
