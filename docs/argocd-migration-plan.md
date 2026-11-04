# ArgoCD migration plan

Status: **implemented.** Each phase landed as its own PR: Phase 0 #377, Phase 1 #378, Phase 2
#380, Phase 3 #381, Phase 4 #382, Phase 5 #383, Phase 6 #384, Phase 7 #385, Phase 8 #386,
Phase 9 #387. The sections below are the plan as it was proposed, kept for the reasoning;
"today" in *Why* describes the pre-migration state, and each phase links its runbook with what
was actually done. The current deploy flow is in `CLAUDE.md` ("Deploying the app").

## Why

Today an app image update reaches the clusters only through Terraform Cloud (TFC):

1. `scripts/bump_app_docker_image_version.sh` edits `app_version` / `short_commit_hash` in all three
   envs' `terraform/env/<env>/aws/us-west-1/cluster-addons-layer/terraform.tfvars`.
2. Merging the bump PR triggers the `ac_app_<env>_cluster_addons_layer` workspace.
3. `helm_release.automation-calculator` in `terraform/modules/aws/main_rails_app/main.tf` runs
   `helm upgrade --atomic` from the local chart, with secrets injected through `set_sensitive`.

This path has hurt us more than once:

- TFC plans that touch Helm or Kubernetes resources go stale: the EKS token is fetched at plan time
  (15-minute STS), so confirming an old production plan fails with "the server has asked for the
  client to provide credentials".
- A failed `helm_release` apply can still write the new values into Terraform state, after which
  every plan shows 0 changes while the cluster is untouched.
- Production applies need a human in the TFC UI, and a deploy and an infrastructure change ride the
  same workspace, so a half-confirmed bump can block an urgent infra fix (or vice versa).

Moving **application deployments** to ArgoCD takes TFC out of the image-bump loop entirely and gives
us a reconciliation loop with visible drift, deploy history and rollback. Terraform keeps owning
infrastructure: EKS, RDS, ACM, IRSA, the ALB controller, external-dns, metrics-server, and ArgoCD
itself.

## Scope

In scope: deploying the `automation-calculator` Rails app (the chart in `helm/automation-calculator`)
to the staging and production clusters via ArgoCD, then removing the Terraform `helm_release`.

Out of scope (possible follow-ups, listed at the end): moving the cluster add-ons to ArgoCD, exposing
the ArgoCD UI on a public hostname with SSO, External Secrets, the development environment (its
cluster is intentionally unprovisioned).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Topology | One ArgoCD per cluster, installed by that env's cluster-addons layer | Clusters are already isolated per env. Hub-and-spoke would need cross-cluster credentials and a control cluster we do not have. |
| Who installs ArgoCD | Terraform `helm_release` in a new module `terraform/modules/kubernetes/argocd`, mirroring the external-dns pattern in `terraform/modules/aws/cluster-addons-layer/main.tf` | ArgoCD is platform, not app. Terraform already bootstraps every other add-on. |
| Where the `Application` lives | Terraform, via a second `helm_release` of the `argocd-apps` chart, plus an `AppProject` | Avoids the `kubernetes_manifest` "CRD must exist at plan time" problem. Lets Terraform inject the ACM certificate ARN so it never lands in this public repo. |
| Source of truth for the image tag | `helm/automation-calculator/values-<env>.yaml` in git, starting in Phase 1 | One source of truth from day one. Terraform reads the same file during the overlap, so there is no drift between the two controllers. A bump becomes one YAML key per env. |
| App secrets | A Terraform-managed `kubernetes_secret_v1` with today's name and keys; the chart stops rendering its own Secret | Secrets stay out of git without a new operator. |
| ArgoCD admin login | A bcrypt **hash** of the admin password held as a sensitive TFC workspace variable (`argocd_admin_password_bcrypt_hash` + `argocd_admin_password_mtime`), passed to the chart through `set_sensitive`; plaintext only in the password manager (`docs/argocd-phase-2-install.md`, section 4) | Rotation becomes an auditable TFC run and cannot be forgotten, and the chart never creates `argocd-initial-admin-secret`. The hash is computed once on a laptop, never with Terraform's `bcrypt()`, which salts differently on every call and would make every run an ArgoCD upgrade. The password is the second gate behind the cluster-admin SSO role, so this does not change who can reach ArgoCD. |
| ArgoCD UI access | `kubectl port-forward` through the existing SSO to `ac_ci_terraform_<env>` chain (`docs/aws-sso-auth.md`); `server.insecure=true`; no Ingress, no Dex | No new attack surface, DNS or ALB. Revisit if the team grows. |
| Production deploy gate | Production `Application` uses **manual** sync. The gate becomes `argocd app sync` after the bump PR merges. Staging gets automated sync with self-heal and prune once cut over. | Mirrors today's "production needs a human" TFC confirm. Can be flipped later. |
| Per-env cutover mechanism | `terraform state rm` of the release in that env's TFC workspace, plus a `manage_helm_release` count toggle on the shared module | A Terraform `removed` block cannot be applied per env: `main_rails_app` is shared by all three addons workspaces, and `removed` requires deleting the resource block from the module. |

## Phases

### Phase 0: preflight (staging)

Runbook with the exact commands: `docs/argocd-phase-0-preflight.md`.

- **Capacity.** Each cluster is one `t3.medium` (desired 1, max 2, no autoscaler;
  `terraform/modules/aws/base-cluster-layer/variables.tf`). The binding limit is **pod count**, not
  CPU or memory: a `t3.medium` allows 17 pods. Today's baseline is roughly 9 to 10 pods and ArgoCD
  adds 4 (controller, repo-server, server, redis). Check before installing with
  `scripts/argocd_preflight.sh` (read-only; exits non-zero when fewer than 4 pod slots would be
  left after ArgoCD, or when the `helm` / `argocd` CLIs are missing). By hand:

  ```bash
  kubectl get node -o jsonpath='{.items[*].status.allocatable.pods}'
  kubectl get pods -A --no-headers | wc -l
  ```

  If headroom is thin, either set staging `desired_size = 2` in
  `terraform/env/staging/aws/us-west-1/base-cluster-layer/main.tf`, or drop the ALB controller
  `replicaCount` to 1 (two replicas on one node buys nothing; the chart defaults to 2 and
  `terraform/modules/aws/cluster-addons-layer/main.tf` does not set it today).
- **Access.** `eval "$(scripts/infra_eng_sso.py up -e staging)"`. Install the `helm` and `argocd`
  CLIs locally (`brew install helm argocd`): `helm` for the render diffs in Phase 1 (CI uses Helm
  4.3.1 through the CircleCI orb), `argocd` for Phase 2 onwards.
- **Versions.** Pinned on 2026-10-26 from `https://argoproj.github.io/argo-helm` (latest stable
  entries in `index.yaml`, found with `scripts/argo_helm_chart_versions.py --fetch`):

  | Chart | Version | appVersion | Consumed by |
  |---|---|---|---|
  | `argo-cd` | `10.11.6` | `v3.5.6` | Phase 2 (`helm_release.argocd`) |
  | `argocd-apps` | `2.0.7` | n/a (CRD manifests only) | Phase 5 (`helm_release.argocd_apps`) |

  Re-pin only deliberately, in an upgrade PR, by re-running the script and updating this table.

### Phase 1: chart refactor and single source of truth (all envs, byte-identical render)

Goal: make the chart deployable from git alone, without changing a single live object.

In `helm/automation-calculator/`:

- `templates/ingress.yaml`: build the ALB annotations from scalar values (`ingress.host`,
  `ingress.certificateArn`, `ingress.albName`) instead of a raw annotations map. Keep `scheme`,
  `target-type` and `load-balancer-name` values identical; changing them replaces the ALB or target
  group. Keep the `actions.redirect-www` folded scalar (trailing newline) so the live annotation does
  not diff. Add an `ingress.enabled` toggle.
- `templates/secret.yaml`: wrap in `{{- if .Values.secrets.create }}`; add
  `helm.sh/resource-policy: keep`; **remove the hard-coded `metadata.namespace`** (today it pins
  `automation-calculator`, so rendering the chart into any other namespace would overwrite the live
  Secret); wrap each value in `{{ required }}` so a render with placeholder values fails instead of
  applying `YOUR_..._HERE`. Also drop the empty `namespace:` line in `templates/deployment.yaml`.
- New `values-staging.yaml`, `values-production.yaml` (and `values-development.yaml` for symmetry)
  holding `image.tag`, `shortCommitHash`, `ingress.host` and `ingress.albName: ac-app-<env>`. The
  tag and hash must equal the current tfvars values so nothing rolls.

In Terraform:

- `terraform/modules/aws/main_rails_app/main.tf`: `values = [file(".../values-${env}.yaml"),
  templatefile("values.yml", { cert_arn })]`. `values.yml` shrinks to `ingress.certificateArn`.
  While there, fix the `logToStdout` / `railsEnv` keys, which are nested under `ingress:` today and
  have no effect.
- Delete the `app_version` and `short_commit_hash` variables from the module and from every env's
  `variables.tf` and `terraform.tfvars`.

Scripts and CI in the same PR:

- `scripts/bump_app_docker_image_version.sh` edits `values-*.yaml` with `yq` (and the `values.yaml`
  default). `scripts/bump_app_docker_image_version_branch.sh` and
  `scripts/watch_app_docker_image_versions.py` follow.
- `scripts/check_app_docker_image_versions.py` reads added `tag:` lines from
  `helm/automation-calculator/values-*.yaml` instead of `app_version` lines from tfvars.

Proof before merge: `helm template` the old and new chart with equivalent values and diff. The only
difference must be the `keep` annotation on the Secret.

Proof after merge (staging auto-applies; **production needs a fresh, promptly confirmed run**):
`kubectl get ingress -o yaml` unchanged, ALB not recreated, Deployment generation unchanged.

Belt and braces: Helm reads `helm.sh/resource-policy` from the **live** object at the upgrade that
drops the Secret from the manifest (Phase 4). So also run, in each env:

```bash
kubectl -n automation-calculator annotate secret automation-calculator-app-secrets helm.sh/resource-policy=keep
```

### Phase 2: install ArgoCD on staging (Terraform)

Runbook with the exact commands: `docs/argocd-phase-2-install.md`.

- New module `terraform/modules/kubernetes/argocd/` (`main.tf`, `variables.tf`, `versions.tf`, lock file)
  with `helm_release.argocd`: chart `argo-cd`, namespace `argocd`, `create_namespace = true`, pinned
  `version`, `wait = true`, `atomic = false`, `cleanup_on_fail = false`, `timeout = 900`. `atomic`
  stays off **for the installs** (Phases 2 and 8): an atomic first install is uninstalled on
  failure, and the realistic failure is the plan-time EKS token expiring during the wait, which a
  non-atomic retry repairs in place. Phase 9 flips it to `true` once both clusters are installed,
  so later upgrades roll back to the working ArgoCD. The `argocd-apps` release (Phase 5) is atomic
  from the start: two CRs, no finalizer, nothing to lose.
- Values: `dex.enabled=false`, `notifications.enabled=false`, `applicationSet.replicas=0` (the
  chart dropped `applicationSet.enabled` in 7.0 and always renders the controller; zero replicas
  keeps it off the pod count), `redis-ha.enabled=false`, single replicas,
  `configs.params."server.insecure"=true`, and explicit resource requests. Suggested starting point:

  | Component | Requests | Memory limit |
  |---|---|---|
  | controller | 100m / 256Mi | 1Gi |
  | repoServer | 50m / 128Mi | 512Mi |
  | server | 50m / 64Mi | 256Mi |
  | redis | 10m / 32Mi | 128Mi |

  No IRSA: the repo is public and ArgoCD makes no AWS calls. The admin password is a bcrypt hash
  held as a sensitive TFC workspace variable and passed through `set_sensitive` (see the
  "ArgoCD admin login" decision and `docs/argocd-phase-2-install.md`, section 4); set it before
  enabling ArgoCD in an environment so the chart never creates `argocd-initial-admin-secret`.
- Wire into each `terraform/env/<env>/aws/us-west-1/cluster-addons-layer/main.tf` as
  `module "argocd"` with `count = var.argocd_enabled ? 1 : 0` and
  `depends_on = [module.cluster_addons]`. `argocd_enabled` defaults to `false`; set it to `true` in
  staging's `terraform.tfvars` only.
- CI and TFC: add `terraform/fmt` and `terraform/validate` jobs for the module to
  `.circleci/config.yml`; add the module directory to `cluster_addons_layer_module_directories` in
  `terraform/modules/tf_cloud/tf_cloud_workspaces/variables.tf`.

Validate:

```bash
kubectl -n argocd get pods
kubectl -n argocd get secret argocd-initial-admin-secret   # NotFound: the password came from TFC
kubectl -n argocd port-forward svc/argocd-server 8080:80
argocd login localhost:8080 --username admin --plaintext   # password from the password manager
argocd app list   # empty
```

### Phase 3: dry run on a scratch copy (staging)

Runbook with the exact commands: `docs/argocd-phase-3-dry-run.md`. Manifests: `argocd/scratch/`.

Learn the tool on something that cannot touch the ALB or the real database. Through the UI or CLI,
not Terraform:

- `AppProject` `scratch`, source limited to this repo, destinations limited to namespace
  `argocd-canary`, `clusterResourceWhitelist` holding only the `argocd-canary` `Namespace` (the
  `CreateNamespace=true` PreSync task goes through the project permission check like any other
  resource).
- `Application` `ac-canary`: same repo and path, `fullnameOverride=ac-canary`,
  `ingress.enabled=false`, `secrets.create=true` with dummy values into a Secret of its own name
  (`ac-canary-app-secrets`), manual sync, **with** the `resources-finalizer.argocd.argoproj.io`
  finalizer so delete cleans up.
- Exercise: sync; bump `image.tag` on a branch and point `targetRevision` at it; `argocd app rollback`
  (with auto-sync off); prune; delete. ArgoCD does not track the auto-created namespace, so the
  runbook deletes `argocd-canary` by hand afterwards.
- Confirm the real namespace's Secret and Deployment are untouched throughout
  (`scripts/argocd_canary_check.sh`, read-only, before and after every step).

### Phase 4: Terraform owns the app namespace and Secret (all envs)

Runbook with the pre-checks, expected plans and rollback: `docs/argocd-phase-4-secret-adoption.md`.

- In `main_rails_app`, add `kubernetes_namespace_v1.automation_calculator` and
  `kubernetes_secret_v1.app_secrets` (name `automation-calculator-app-secrets`, `type = "Opaque"`,
  `data` = the six values built from the same expressions the `set_sensitive` blocks use today).
  Add `kubernetes ~> 2.16` to the module's `versions.tf`. The namespace ignores label and
  annotation changes (its metadata is not Terraform's) and carries `prevent_destroy` (deleting it
  deletes the Ingress and the ALB). The Secret declares the labels and annotations Helm left on the
  live object, including `meta.helm.sh/release-*`, so the import plans clean and a revert can
  re-adopt it into the release.
- Root-module `import` blocks in the staging and production env configs
  (`imports_argocd_phase4.tf`), so the live objects are adopted rather than recreated: id
  `automation-calculator` for the namespace and
  `automation-calculator/automation-calculator-app-secrets` for the Secret. Development gets no
  import blocks: its cluster is unprovisioned, so there is nothing to adopt and an `import` of a
  missing object fails the plan; a future development apply creates both resources. The import
  files are deleted in a follow-up PR once both environments have applied.
- Same PR: `secrets.create: false` in every `values-<env>.yaml` (`values.yaml` keeps the default
  `true` for standalone renders such as the Phase 3 canary); delete the six `set_sensitive`
  blocks. Helm leaves the Secret in place because of the `keep` policy, so there is no window
  without a Secret. The post-import plan is at most an in-place label update.
- Validate per env: Secret data checksum unchanged, pods not restarted,
  `helm -n automation-calculator status automation-calculator` healthy. Production: fresh plan,
  confirm promptly (the import reads the live Secret with the plan-time token).

### Phase 5: the real Application on staging, adopted in place

Runbook with the expected plan, the diff inspection, the first sync, the checks and the rollback:
`docs/argocd-phase-5-adopt-application.md`.

Add to the `argocd` module a `helm_release.argocd_apps` (chart `argocd-apps`,
`depends_on = [helm_release.argocd]`) that creates:

- `AppProject` `automation-calculator`: destinations limited to namespace `automation-calculator`,
  source repos limited to this repository.
- `Application` **named `automation-calculator`** with `spec.source.helm.releaseName:
  automation-calculator`. The release name feeds `app.kubernetes.io/instance` in the Deployment's
  immutable `spec.selector.matchLabels` (`templates/_helpers.tpl`). Any other name makes the
  Deployment sync fail and, worse, updates the Service selector to match zero pods.
- `repoURL` = this repo, `targetRevision: main`, `path: helm/automation-calculator`,
  `valueFiles: [values.yaml, values-<env>.yaml]`, `parameters:
  [ingress.certificateArn=<ACM ARN output of main_rails_app>]`, destination namespace
  `automation-calculator`, `syncOptions: [CreateNamespace=true]`.
- **No `resources-finalizer`** on this Application. With it, deleting the Application (a Terraform
  destroy, a `helm_release` replace, a rename) cascade-deletes the Ingress and therefore the ALB.
- `syncPolicy` manual at first.

Then:

1. In the UI, inspect the diff. Expected: only the `argocd.argoproj.io/tracking-id` annotation (and
   `kubectl.kubernetes.io/last-applied-configuration` after the first sync). Any pod-template diff
   means a values mismatch; fix it first, do not sync.
2. `argocd app sync automation-calculator`. Confirm the Deployment generation is unchanged, the
   Ingress is unchanged, and the site serves.
3. No ServerSideApply, Replace or `ignoreDifferences` is needed for this chart.

Rollback at this stage: `argocd app delete automation-calculator --cascade=false` (or
`argocd_enabled=false`). Terraform's release still owns everything. Keep the Application on manual
sync while Terraform still manages the release: both read `values-<env>.yaml`, but two controllers
must never reconcile the same Deployment.

### Phase 6: retire the Terraform release on staging only

Runbook with the state-address reasoning, the expected plan per step and the rollback:
`docs/argocd-phase-6-retire-staging-release.md`.

- Add `manage_helm_release` (default `true`) to `main_rails_app` and `count` on the `helm_release`.
  The instance address becomes `helm_release.automation-calculator[0]`; a `moved` block in the
  module records the move (Phase 9 deletes it with the resource). The release also gets
  `prevent_destroy`, so flipping the toggle before the `state rm` fails the plan instead of
  running `helm uninstall`. Each env's `cluster-addons-layer` gets `manage_app_helm_release` and
  the three `argocd_application_{automated_sync,prune,self_heal}` variables (defaults false).
- Runbook, run back to back within minutes, with no other merges in the window (staging
  auto-applies):
  1. From `terraform/env/staging/aws/us-west-1/cluster-addons-layer` with `TFE_TOKEN` set:
     `terraform init`, then
     `terraform state rm module.main_rails_app.helm_release.automation-calculator` (un-indexed:
     the state was last written by a configuration without `count`; Phase 8 on production will
     `state rm` the indexed `[0]` address because production applies this PR's move).
  2. Merge the PR that sets `manage_app_helm_release = false` in staging's `terraform.tfvars`.
     Staging plans 0 changes; production plans the state move only (`0 to add, 0 to change, 0 to
     destroy`, but the run **needs a confirm** to record the move). Preview both with local
     speculative `terraform plan` runs before merging: staging errors with `Instance cannot be
     destroyed` until the `state rm` is done, and must not be merged while it does.
  3. Delete the Helm history only:
     `kubectl -n automation-calculator delete secret -l owner=helm,name=automation-calculator`.
     **Never run `helm uninstall`**: it deletes the Ingress, which deletes the ALB. The history
     stays until after the merge on purpose: while it exists, a stray run in the `state rm` window
     fails on `cannot re-use a name` instead of re-adopting the release.
- Flip the staging Application to `syncPolicy.automated: { prune: true, selfHeal: true }` through
  `argocd_application_automated_sync = true`, `argocd_application_prune = true`,
  `argocd_application_self_heal = true` in staging's tfvars, as its own merge after step 3 (a
  separate commit on the Phase 6 branch). Prune is safe because the Terraform-managed Secret
  carries no ArgoCD tracking annotation; the runbook lists what to check before enabling it.
- Rollback after this point is a git revert PR (ArgoCD syncs it) or a manual
  `helm upgrade --install`.

### Phase 7: prove and soak the new path on staging

Runbook with the exact commands, the failure triage and the definition of "manual intervention":
`docs/argocd-phase-7-staging-soak.md`. Cycles are recorded in `docs/argocd-staging-soak-log.md`.

- Run a real bump through the updated script, merge, and watch ArgoCD sync (polling default is
  3 minutes). Verify `https://staging.automation-calculations.io/health`, the `SHORT_COMMIT_HASH`
  env var on the new pod, and `argocd app history automation-calculator`
  (`scripts/argocd_staging_verify.sh`, read-only, checks all of that against `values-staging.yaml`
  and that `helm list` is still empty). Confirm the staging TFC workspace planned 0 changes for
  that merge.
- Test the real rollback path: a revert PR, synced by ArgoCD. (`argocd app rollback` is refused
  while automated sync is on.)
- Soak gate before production: at least three bump cycles and at least one week without manual
  intervention. `scripts/argocd_soak_log.py add` records each cycle and
  `scripts/argocd_soak_log.py status` evaluates the gate and writes the result into the log.

### Phase 8: production

Runbook with the soak-gate check, the production preflight, the expected plan per merge, the
state address and the rollback at each step: `docs/argocd-phase-8-production.md`. One branch,
two commits, landed as **separate merges** in this order (each a fresh, promptly confirmed
production run); the second is reverted off the branch and re-landed as a follow-up PR if the
first has to merge alone, as Phase 6 did with the automated-sync flip.

- Gate: `scripts/argocd_soak_log.py status` prints PASS, and the Phase 0 preflight passes on
  production (`scripts/argocd_preflight.sh`). The ALB `replicaCount` reduction was never applied
  (staging had the headroom), so production may first need it or `desired_size = 2` in its own PR.
- Commit A: set `argocd_enabled = true` in production's `terraform.tfvars` (2 to add in
  `module.argocd[0]`; confirm promptly). The same `argocd_apps` release creates the production
  `AppProject` and `Application`, with `syncPolicy` manual: the module defaults
  (`argocd_manage_application` true, the three `argocd_application_*` variables false) do it, and
  production's tfvars set none of them.
- Repeat the Phase 5 checks: diff shows only tracking metadata, `argocd app sync`, no rollout,
  Ingress untouched. `scripts/argocd_staging_verify.sh --env production` (the name is historical)
  with `--expect-helm-release` while Terraform still owns the release.
- Commit B: run the Phase 6 runbook against the production workspace, with the **indexed**
  address, `terraform state rm 'module.main_rails_app.helm_release.automation-calculator[0]'`
  (production applied the Phase 6 move), then `manage_app_helm_release = false` in production
  tfvars (plans 0 changes), then delete the Helm history.
- Production stays on manual sync. A production deploy is now: merge the bump PR, then
  `argocd app sync automation-calculator` through a port-forward. Decide separately whether to move
  production to automated sync, which would make PR review the only gate.

### Phase 9: decommission

Runbook with the preconditions (no release in either state or on either cluster, the Phase 4
objects in both states), the expected plans and the rollback: `docs/argocd-phase-9-decommission.md`.

- Delete from `main_rails_app`: the `helm_release`, its `moved` block, `manage_helm_release`,
  `automation_calculator_helm_release_local_path`, `values.yml`, and the `helm` provider
  requirement. Keep the module for RDS, ACM, the namespace and the Secret. Both envs ran
  `terraform state rm` on the release in Phases 6 and 8, so deleting the block plans 0 changes;
  the runbook proves that before the merge, because with the block gone there is no
  `prevent_destroy` left to catch a release that is still in state.
- Each env's `cluster-addons-layer` loses `manage_app_helm_release` and the chart-path input, and
  staging and production lose `imports_argocd_phase4.tf` (applied in Phase 4).
- Remove `helm/automation-calculator` from `cluster_addons_layer_module_directories` so chart
  changes stop queueing TFC runs (and stale production plans). `terraform/modules/aws/main_rails_app`
  **stays** in the list, unlike what this bullet first said: the module still owns the namespace,
  the Secret, RDS and ACM in every addons workspace, so changes to it must keep queueing their runs.
- Update `CLAUDE.md` (layout, apply order, how deploys work, scripts), the README setup steps, and
  the status line at the top of this document. `.circleci/config.yml` needed no change: `helm lint`
  still guards the chart ArgoCD deploys and every validated module still exists.

## Risks and mitigations

- **Ingress deletion means ALB deletion**, and external-dns can leave an orphaned TXT ownership record
  that blocks recreating the A record. Mitigation: adopt in place, no finalizer on the real
  Application, no `helm uninstall`, no prune until Terraform has forgotten the release.
- **Pod-count ceiling on `t3.medium`.** Mitigation: Phase 0 count; bump `desired_size` if needed.
- **Stale TFC plans on production.** Mitigation: fresh runs only, confirmed immediately; local
  speculative plans before every production-affecting merge.
- **Two controllers on one Deployment.** Mitigation: ArgoCD stays on manual sync until
  `terraform state rm`; both controllers read the same `values-<env>.yaml` in the meantime.
- **Public repository.** The Application spec carries only the certificate ARN as a parameter;
  secrets never enter git.
- **`terraform state rm` window.** Between the `state rm` and the toggle merge, a staging run would
  try to `helm install` over existing objects and fail. Mitigation: run the two steps back to back
  with the PR already approved.

## Verification checklist (per env)

```bash
kubectl -n argocd get pods
argocd app get automation-calculator            # Synced / Healthy
kubectl -n automation-calculator get deploy,ing,secret
curl -fsS https://<host>/health
helm -n automation-calculator list              # empty after Phase 6 (staging) / Phase 8 (production)
```

## Follow-ups (not in scope)

- ArgoCD UI behind the ALB with Google SSO through Dex.
- External Secrets Operator in place of the Terraform-managed Secret.
- Move the cluster add-ons (ALB controller, external-dns, metrics-server) to ArgoCD.
- Per-env promotion of image tags (now trivial with separate values files).
