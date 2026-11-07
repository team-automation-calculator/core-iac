output "automation_calculator_app_certificate_arn" {
  description = "ARN of the ACM certificate for the app host and its www. alias. Injected into the Helm release here and, since ArgoCD migration Phase 5, into the ArgoCD Application as the ingress.certificateArn parameter (terraform/modules/aws/argocd)."
  value       = aws_acm_certificate.automation_calculator_app.arn
}
