# argocd

Installs ArgoCD into an EKS cluster and, by default, the app's `AppProject` and `Application`,
with two `helm_release`s, mirroring how `cluster-addons-layer` installs external-dns. Phases 2 and
5 of `docs/argocd-migration-plan.md`.

The module takes no cluster inputs: like the other add-on modules it relies on the `helm` provider
configured by the calling env config (`terraform/env/<env>/aws/us-west-1/cluster-addons-layer`).
Each env wires it as `module "argocd"` behind `var.argocd_enabled` (default `false`), so an env
without the flag plans zero changes.

## `helm_release.argocd` (Phase 2)

- Chart [`argo-cd`](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd), namespace
  `argocd` (created by the release), chart version pinned to the Phase 0 pin in the plan.
- Dex, notifications and Redis HA off; the ApplicationSet controller scaled to zero (the chart no
  longer has `applicationSet.enabled`). Four pods: application controller, repo server, server,
  redis.
- `server.insecure=true`: the UI/API is only reachable through `kubectl port-forward`. No Ingress.
- Explicit resource requests and memory limits sized for a single `t3.medium`.
- No IRSA, no admin password management (use `argocd-initial-admin-secret`, then
  `argocd account update-password`).
- `wait = true`, `atomic = false`, `cleanup_on_fail = false`, `timeout = 900`: a failed install stays
  on the cluster for inspection instead of rolling back.

Validation and first login: `docs/argocd-phase-2-install.md`.

## `helm_release.argocd_apps` (Phase 5, `manage_application = true`)

A second release, of the [`argocd-apps`](https://github.com/argoproj/argo-helm/tree/main/charts/argocd-apps)
chart (CR manifests only, no controller), `depends_on` the first so the CRDs exist. It renders:

- `AppProject` `automation-calculator`: `sourceRepos` limited to `app_repo_url` (this repository),
  destinations limited to `app_namespace` on the local cluster, and a `clusterResourceWhitelist`
  holding only the `app_namespace` `Namespace` (what `CreateNamespace=true` needs; a Phase 3
  finding).
- `Application` `automation-calculator` (the name is a local, not a variable: it is the Helm release
  name inside the Application and therefore `app.kubernetes.io/instance` in the Deployment's
  immutable selector). Source `app_repo_url` at `app_target_revision`, path `app_chart_path`,
  `valueFiles: [values.yaml, values-<environment_name>.yaml]`, one parameter
  `ingress.certificateArn = app_certificate_arn` (the ACM ARN never enters this public repository
  through git). Destination `app_namespace`, `syncOptions: [CreateNamespace=true]`.
- **No `resources-finalizer.argocd.argoproj.io`**: deleting the Application (a Terraform destroy, a
  release replace, a rename) must never cascade to the Ingress and therefore the ALB.
- `syncPolicy` is manual unless `application_automated_sync` is true, in which case an `automated`
  block with `application_prune` / `application_self_heal` is rendered. Keep it manual while
  Terraform's `main_rails_app` release still manages the app (Phase 6 flips staging after
  `terraform state rm`).

Adoption, diff inspection, first sync and rollback: `docs/argocd-phase-5-adopt-application.md`.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `argocd_chart_version` | `10.11.6` | argo-cd chart version (Argo CD v3.5.6). Re-pin only in an upgrade PR together with the plan's Versions table. |
| `argocd_namespace` | `argocd` | Namespace both releases install into; the first creates it. |
| `argocd_apps_chart_version` | `2.0.7` | argocd-apps chart version. Same re-pin rule. |
| `manage_application` | `true` | Render `helm_release.argocd_apps` (the AppProject and Application). `false` installs ArgoCD alone. |
| `environment_name` | (required) | Selects `values-<environment_name>.yaml`. |
| `app_repo_url` | (required) | This repository's git URL: the Application source and the only source the AppProject allows. |
| `app_certificate_arn` | (required) | ACM certificate ARN for the Ingress; `main_rails_app`'s `automation_calculator_app_certificate_arn` output. Validated to start with `arn:aws:acm:` when `manage_application` is true. |
| `app_target_revision` | `main` | Git revision the Application tracks. |
| `app_chart_path` | `helm/automation-calculator` | Chart path inside the repository. |
| `app_namespace` | `automation-calculator` | Destination namespace; must match Terraform's release and Secret. |
| `application_automated_sync` | `false` | Render `syncPolicy.automated`. Phase 6 and later only, after that env's Terraform release is out of state and its Helm history deleted (`docs/argocd-phase-6-retire-staging-release.md`). The env configs expose it as `argocd_application_automated_sync`. |
| `application_prune` | `false` | `automated.prune`; read only when automated sync is on. |
| `application_self_heal` | `false` | `automated.selfHeal`; read only when automated sync is on. |

## Outputs

`argocd_chart_version`, `argocd_namespace`, `argocd_release_name`, `argocd_apps_chart_version`
(null when `manage_application` is false) and `application_name` (`automation-calculator`, or null).
