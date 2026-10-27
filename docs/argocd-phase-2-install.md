# ArgoCD migration Phase 2: install runbook (staging)

Companion to Phase 2 of `argocd-migration-plan.md`. Terraform does the install; this runbook covers
what to expect from the TFC runs and how to verify the result and log in for the first time.
Nothing here changes the cluster except the TFC apply itself.

## 1. What the PR changes

- `terraform/modules/aws/argocd/`: one `helm_release.argocd` of the `argo-cd` chart (version pinned
  under Phase 0 "Versions" in the plan), namespace `argocd`, `wait = true`, `atomic = false`,
  `cleanup_on_fail = false`, `timeout = 900`. Dex, notifications and Redis HA off, the
  ApplicationSet controller scaled to zero, single replicas, `server.insecure=true`, explicit
  resource requests and memory limits. No IRSA, no Ingress, no admin password management.
- Each env's `cluster-addons-layer/main.tf` gains `module "argocd"` behind
  `var.argocd_enabled` (default `false`). Only staging's `terraform.tfvars` sets it to `true`.
- The module is added to `cluster_addons_layer_module_directories` so a change under
  `terraform/modules/aws/argocd` queues a cluster-addons run, and to `.circleci/config.yml` for
  fmt and validate.

## 2. Expected TFC plans

| Workspace | Expected plan |
|---|---|
| `ac_app_staging_cluster_addons_layer` | 1 to add: `module.argocd[0].helm_release.argocd`. Auto-applies. |
| `ac_app_development_cluster_addons_layer` | 0 changes (`argocd_enabled` is false). |
| `ac_app_production_cluster_addons_layer` | 0 changes (`argocd_enabled` is false). |

Anything else in the plan (a change to `module.cluster_addons` or `module.main_rails_app`) is not
this PR and must be understood before merging.

The staging apply runs `helm install` with `wait = true`, so it blocks until all ArgoCD pods are
ready, up to 15 minutes. If it fails, the release stays on the cluster for inspection
(`atomic = false`); fix the cause and re-queue the run. Do not `helm uninstall` by hand unless the
release is being abandoned: Terraform state would then point at a release that no longer exists.

## 3. Verify

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # SSO login, kubeconfig, AWS_PROFILE
kubectl config current-context                                # must be the ac_app_staging cluster

kubectl -n argocd get pods
```

Expected: four Running pods (`argocd-application-controller-0`, `argocd-repo-server-*`,
`argocd-server-*`, `argocd-redis-*`) plus a Completed `argocd-redis-secret-init-*` Job pod from the
install. No dex, notifications or applicationset pods. The ApplicationSet Deployment exists with 0
replicas:

```bash
kubectl -n argocd get deploy argocd-applicationset-controller   # READY 0/0
helm -n argocd list                                             # argocd, deployed, chart argo-cd-10.11.6
kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'   # true
```

Pod headroom after the install (the Phase 0 check, re-run):

```bash
scripts/argocd_preflight.sh
```

## 4. First login

The chart generates the admin password into `argocd-initial-admin-secret`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

In one terminal, keep a port-forward open (the server listens on plain HTTP because of
`server.insecure=true`):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

In another:

```bash
argocd login localhost:8080 --username admin --plaintext   # paste the password above
argocd app list                                            # empty until Phase 5
argocd version                                             # server v3.5.6
```

The UI is `http://localhost:8080` while the port-forward runs.

Rotate the generated password now and delete the bootstrap Secret, as the ArgoCD docs recommend:

```bash
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

Terraform does not manage the password (a `bcrypt()` hash changes on every run), so this rotation
never shows up as drift.

## 5. Rollback

Set `argocd_enabled = false` in staging's `terraform.tfvars` through a PR. Terraform destroys the
release and, with it, the `argocd` namespace. The chart keeps its CRDs on uninstall
(`crds.keep: true`); they are harmless and will be reused by a reinstall. Nothing in the
`automation-calculator` namespace is touched: ArgoCD has no Applications yet.

## 6. Done when

- Staging TFC run applied with exactly 1 resource added; development and production planned 0.
- `kubectl -n argocd get pods` shows the four pods Running.
- `argocd login` succeeds through the port-forward and `argocd app list` is empty.
- `scripts/argocd_preflight.sh` still exits 0 on staging (headroom for the Phase 3 canary pods).
