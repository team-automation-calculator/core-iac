# ArgoCD migration Phase 2: install runbook (staging)

Companion to Phase 2 of `argocd-migration-plan.md`. Terraform does the install; this runbook covers
what to expect from the TFC runs and how to verify the result and log in for the first time.
Nothing here changes the cluster except the TFC apply itself.

## 1. What the PR changes

- `terraform/modules/aws/argocd/`: one `helm_release.argocd` of the `argo-cd` chart (version pinned
  under Phase 0 "Versions" in the plan), namespace `argocd`, `wait = true`, `atomic = false`,
  `cleanup_on_fail = false`, `timeout = 900`. Dex, notifications and Redis HA off, the
  ApplicationSet controller scaled to zero, single replicas, `server.insecure=true`, explicit
  resource requests and memory limits. No IRSA, no Ingress. The admin password comes in as a
  bcrypt hash from two TFC workspace variables (section 4), through `set_sensitive`.
  (Since Phase 5 the module also has `helm_release.argocd_apps`, the app's AppProject and
  Application, behind `manage_application`; see `docs/argocd-phase-5-adopt-application.md`. This
  runbook describes the Phase 2 install alone.)
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

## 4. Admin password and first login

The admin password is a Terraform input, but only ever as a **bcrypt hash**. Do this **before**
merging the PR that sets `argocd_enabled = true` for the environment, so the very first install
already carries the password and the chart never creates `argocd-initial-admin-secret`.

### 4.1 Generate the password and its hash (laptop only)

```bash
brew install argocd                                   # if not already installed (Phase 0)
PW="$(openssl rand -base64 30)"                       # or let the password manager generate one
argocd account bcrypt --password "$PW"                # prints a $2a$10$... hash, 60 characters
date -u +%Y-%m-%dT%H:%M:%SZ                           # the mtime, e.g. 2026-10-26T18:00:00Z
```

Store the plaintext in the team password manager under the environment's ArgoCD entry, with the
mtime noted. The plaintext goes nowhere else: not git, not `terraform.tfvars`, not TFC.

### 4.2 Set the TFC workspace variables

On `ac_app_<env>_cluster_addons_layer`, as Terraform variables (not environment variables):

| Variable | Value | Sensitive |
|---|---|---|
| `argocd_admin_password_bcrypt_hash` | the `$2a$10$...` hash | yes |
| `argocd_admin_password_mtime` | the timestamp from above | no |

Both must be set together; the module rejects one without the other, and rejects anything that is
not a bcrypt hash, so pasting the plaintext by mistake fails the plan instead of installing it as
the password. The hash reaches the chart through `set_sensitive`
(`configs.secret.argocdServerAdminPassword` / `argocdServerAdminPasswordMtime`), so plan output
redacts it; it does live in the workspace state, which is acceptable for a bcrypt hash of a random
password and is readable only by people who already control the cluster through TFC.

Why a hash and not `bcrypt()` in HCL: Terraform's `bcrypt()` salts differently on every call, so
it would upgrade ArgoCD on every run. Why set the mtime: the chart otherwise stamps the render time,
and every later `helm upgrade` would log every session out.

### 4.3 First login

In one terminal, keep a port-forward open (the server listens on plain HTTP because of
`server.insecure=true`):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

In another:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret   # must return NotFound: Terraform set the password
argocd login localhost:8080 --username admin --plaintext   # password from the password manager
argocd app list                                            # empty until Phase 5
argocd version                                             # server v3.5.6
```

The UI is `http://localhost:8080` while the port-forward runs.

The port-forward path already requires the cluster-admin SSO role, so the password is the second
gate, not the first (see the "ArgoCD admin login" and "ArgoCD UI access" rows in the plan's
Decisions table).

### 4.4 Rotation

Generate a new password and hash as in 4.1, update both TFC variables, and queue a run: the plan
shows one in-place change to `helm_release.argocd` (production: fresh run, confirm promptly). The
new mtime invalidates every existing session. Do not use `argocd account update-password`: the next
Terraform run would put the Terraform-managed hash back.

### 4.5 If the variables were not set before the first install

The chart generated a random password into `argocd-initial-admin-secret`. Read it, log in, then
follow 4.1 and 4.2; the next run replaces the generated password and you can delete the bootstrap
Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd delete secret argocd-initial-admin-secret   # after the run that set the hash applied
```

Phase 8 repeats this section for the production workspace before enabling ArgoCD there.

## 5. Rollback

Set `argocd_enabled = false` in staging's `terraform.tfvars` through a PR. Terraform destroys the
release and, with it, the `argocd` namespace. The chart keeps its CRDs on uninstall
(`crds.keep: true`); they are harmless and will be reused by a reinstall. Nothing in the
`automation-calculator` namespace is touched: at this phase ArgoCD has no Applications yet, and
the one Phase 5 adds carries no finalizer, so its deletion never cascades either.

## 6. Done when

- Staging TFC run applied with exactly 1 resource added; development and production planned 0.
- `kubectl -n argocd get pods` shows the four pods Running.
- `argocd login` succeeds through the port-forward and `argocd app list` is empty.
- The admin password hash and mtime are set as TFC workspace variables, the plaintext is in the
  password manager, and `argocd-initial-admin-secret` does not exist in the `argocd` namespace.
- `scripts/argocd_preflight.sh` still exits 0 on staging (headroom for the Phase 3 canary pods).
