# ArgoCD migration Phase 4 (docs/argocd-migration-plan.md; runbook
# docs/argocd-phase-4-secret-adoption.md): adopt the live app namespace and
# Secret into Terraform instead of recreating them. Helm created both through
# helm_release.automation-calculator (create_namespace and the chart's
# templates/secret.yaml); from this phase on they are the
# kubernetes_namespace_v1 / kubernetes_secret_v1 resources in
# terraform/modules/aws/main_rails_app.
#
# Import blocks are idempotent: Terraform imports on the first plan that sees
# them and ignores them once the objects are in state. Delete this file after
# the Phase 4 apply has run in this environment (at the latest in Phase 9): a
# block whose object no longer exists on the cluster fails the plan.

import {
  to = module.main_rails_app.kubernetes_namespace_v1.automation_calculator
  id = "automation-calculator"
}

import {
  to = module.main_rails_app.kubernetes_secret_v1.app_secrets
  id = "automation-calculator/automation-calculator-app-secrets"
}
