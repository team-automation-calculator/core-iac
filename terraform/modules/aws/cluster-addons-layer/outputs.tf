# Fed to main_rails_app's addons_dependency so the app Helm release is
# installed after the add-ons its Ingress needs (the ALB controller for the
# "alb" IngressClass and admission webhook, external-dns for the host record).
# This replaces a module-level depends_on in the env configs, which deferred
# every data source in main_rails_app to apply time whenever an add-on had
# pending changes and planned the ACM validation records for replacement.
output "app_helm_release_dependencies" {
  description = "Names of the add-on Helm releases the app Helm release must be installed after; used only for ordering."
  value = [
    helm_release.aws_load_balancer_controller.name,
    helm_release.external-dns.name,
  ]
}
