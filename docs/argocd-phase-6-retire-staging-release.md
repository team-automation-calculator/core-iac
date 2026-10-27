# ArgoCD migration Phase 6: retire the Terraform Helm release on staging

Companion to Phase 6 of `argocd-migration-plan.md`. After Phase 5, two controllers know about the
app on staging: Terraform's `helm_release.automation-calculator` (the `ac_app_staging_cluster_addons_layer`
workspace) and the ArgoCD `Application` `automation-calculator`, on manual sync. This phase makes
Terraform **forget** the release, without destroying it, and then hands the app to ArgoCD with
automated sync, prune and self-heal. Nothing on the cluster is recreated or rolled: the Service,
Deployment and Ingress keep running throughout; the only cluster writes are the deletion of Helm's
own history records and ArgoCD's sync-policy change.

Production is untouched (its workspace records a state move and nothing else; section 4). Phase 8
repeats this runbook against production.

The two rules for the whole phase: **Terraform must never plan a destroy of the release** (a destroy
is `helm uninstall`, which deletes the Ingress and therefore the ALB), and **two controllers must
never reconcile the same Deployment** (ArgoCD stays on manual sync until Terraform has forgotten
the release). Every step below exists to hold one of those two.

## 1. What the PR changes

- `terraform/modules/aws/main_rails_app/main.tf`
  - `helm_release.automation-calculator` gets `count = var.manage_helm_release ? 1 : 0`. Its
    instance address therefore changes from `module.main_rails_app.helm_release.automation-calculator`
    to `module.main_rails_app.helm_release.automation-calculator[0]`. A `moved` block in the module
    records that move explicitly (Terraform would propose the same move on its own; the block makes
    it deterministic and reviewable).
  - `lifecycle { prevent_destroy = true }` on the release. It turns the one catastrophic ordering
    mistake (the toggle merged before the `state rm`, section 2) into a **plan error** instead of
    an ALB deletion. Like the namespace guard from Phase 4 it only holds while the resource block
    exists; Phase 9 removes the block only after every env has forgotten the release.
  - `variables.tf`: `manage_helm_release`, default `true`.
- Each env's `cluster-addons-layer`: `variables.tf` gains `manage_app_helm_release` (default
  `true`, passed as `manage_helm_release`) and `argocd_application_automated_sync`,
  `argocd_application_prune`, `argocd_application_self_heal` (all default `false`, passed to
  `module "argocd"` as the Phase 5 variables of the same name without the prefix).
- `terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars`:
  `manage_app_helm_release = false`.
- The automated-sync flip for staging (`argocd_application_automated_sync = true`,
  `argocd_application_prune = true`, `argocd_application_self_heal = true` in the same tfvars) is a
  **separate commit** on the same branch, because it must land as its own merge after the Helm
  history is gone (section 3, step 6).

## 2. Why the order is what it is

**The state address.** The staging and production state files hold the release at the
un-indexed address `module.main_rails_app.helm_release.automation-calculator`, because that is what
the configuration said when they were last written. Addresses in state only change when an apply
records a move. So:

- `terraform state rm` **before** the toggle merge targets the un-indexed address
  `module.main_rails_app.helm_release.automation-calculator`. That is the address this runbook uses
  for staging. (`terraform state rm` edits the state directly and works even when the local
  checkout already has the `count` configuration; verified with Terraform 1.17.)
- Once a workspace has applied this PR with `manage_app_helm_release = true` (production, in this
  phase), its state holds `module.main_rails_app.helm_release.automation-calculator[0]`. **Phase 8
  must `state rm` the indexed address** (quote it in zsh:
  `'module.main_rails_app.helm_release.automation-calculator[0]'`).

**What each ordering plans.** With the release still in state:

| Config | Plan |
|---|---|
| `manage_app_helm_release = true` (production) | the move `…automation-calculator` to `…automation-calculator[0]`; `0 to add, 0 to change, 0 to destroy`. The plan is **not empty** (the move must be recorded), so TFC asks for a confirm on production. |
| `manage_app_helm_release = false` (staging) **without** the `state rm` | the move, then `[0] will be destroyed (because index [0] is out of range for count)`: 1 to destroy, which is `helm uninstall`. **`prevent_destroy` fails this plan** with `Instance cannot be destroyed`, so staging auto-apply cannot run it. The fix is the `state rm`, never removing the guard. |

With the release out of state (after the `state rm`): `manage_app_helm_release = false` plans
**no changes**; the `moved` block finds nothing at its `from` address and is a no-op.
`manage_app_helm_release = true` (what a revert of the toggle would do) plans `[0] will be
created`, which is a `helm install` (section 6).

**The `state rm` window.** Between the `state rm` and the toggle merge, `main` still says "manage
the release" while the state no longer has it. Any staging run in that window (any merge touching
the addons workspace) plans `helm_release.automation-calculator will be created` and the apply
runs `helm install` against a cluster where release `automation-calculator` still exists. Helm
refuses (`cannot re-use a name that is still in use`) **because the Helm history is still there**,
the apply fails, and the state stays without the release: the window fails safe. That is why the
Helm history is deleted only **after** the toggle merge (step 5, never earlier): without the
history, a stray `helm install` would adopt the live objects, re-record the release in state, and
the toggle merge would then plan a destroy (blocked by `prevent_destroy`, but now you are untangling
a half-state). Keep the window to minutes, with the PR approved and no other merges queued.

**Two controllers on one Deployment.** Until the `state rm` is applied, Terraform can still
`helm upgrade` the Deployment on any addons run, and ArgoCD could sync it. They agree while `main`
and the last staging apply match, but they must never both reconcile on their own: the Application
stays on manual sync until step 6, which is the last step.

## 3. The sequence

Run on one sitting, in this order, with the PR reviewed and approved before step 2 starts. Staging
auto-applies on merge; nothing else may be merged between step 2 and step 4.

### Step 0: pre-checks (read-only)

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # SSO login, kubeconfig, AWS_PROFILE
kubectl config current-context                                # must be the ac_app_staging cluster
mkdir -p tmp
CANARY_APP=automation-calculator scripts/argocd_canary_check.sh | tee tmp/phase6-00-baseline.txt
kubectl -n automation-calculator get pods -o wide | tee tmp/phase6-00-pods.txt
kubectl -n automation-calculator get ingress automation-calculator -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
helm -n automation-calculator list                            # one release, STATUS deployed
```

The Application must be **Synced and Healthy on manual sync** before anything else; a pending bump
(OutOfSync on the pod template) means Terraform and `main` disagree and the hand-over would roll
the app. Port-forward and log in as in `argocd-phase-5-adopt-application.md` section 4, then:

```bash
argocd app get automation-calculator        # Sync Status: Synced, Health: Healthy, Sync Policy: Manual
argocd app diff automation-calculator       # no output, exit 0
kubectl -n argocd get application.argoproj.io automation-calculator -o jsonpath='{.metadata.finalizers}'; echo   # empty
```

Also confirm the workspace is idle (no run planning or waiting for confirmation in the TFC UI for
`ac_app_staging_cluster_addons_layer`) and that the last applied run planned 0 changes, so the
`state rm` is the only thing about to change.

### Step 1: speculative plans before the `state rm` (what "wrong" looks like)

From the PR branch checkout, with `TFE_TOKEN` set, `terraform plan` from an env directory runs a
speculative plan remotely with the local configuration and streams it; nothing is applied.

```bash
cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
terraform init
terraform plan | tee ../../../../../../tmp/phase6-01-staging-before-rm.txt
```

Expected on staging **before** the `state rm`: the plan **errors** with `Instance cannot be
destroyed` on `module.main_rails_app.helm_release.automation-calculator[0]`, after showing
`1 to destroy ... (because index [0] is out of range for count) (moved from
module.main_rails_app.helm_release.automation-calculator)`. The speculative run TFC attached to the
PR shows the same error. That is the guard working: **this PR must not be merged while the staging
plan looks like this.**

```bash
cd ../../../../../production/aws/us-west-1/cluster-addons-layer
terraform init
terraform plan | tee ../../../../../../tmp/phase6-01-production.txt
```

Expected on production (now and after step 2, unchanged): one line
`module.main_rails_app.helm_release.automation-calculator has moved to
module.main_rails_app.helm_release.automation-calculator[0]` and
`Plan: 0 to add, 0 to change, 0 to destroy.` Anything else on `module.main_rails_app`,
`module.cluster_addons` or `module.argocd` is not this PR: stop.

### Step 2: forget the release in the staging workspace

```bash
cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
terraform state list | grep helm_release          # module.main_rails_app.helm_release.automation-calculator
terraform state pull > ../../../../../../tmp/phase6-02-staging-state-before-rm.json   # backup; contains secrets, delete it at the end
terraform state rm module.main_rails_app.helm_release.automation-calculator
terraform state list | grep helm_release          # nothing
```

Un-indexed address, as explained in section 2. `state rm` takes the workspace lock and writes a new
state version (visible under the workspace's States tab). It fails if a run holds the lock; wait
for the run, do not force-unlock. It does not touch the cluster: `helm -n automation-calculator
list` still shows the release, and the pods, Ingress and ALB are exactly as in step 0.

From this moment until step 4 completes, the window of section 2 is open.

### Step 3: speculative plans again

```bash
terraform plan | tee ../../../../../../tmp/phase6-03-staging-after-rm.txt
```

Expected on staging: `No changes. Your infrastructure matches the configuration.` In particular
nothing on `module.argocd[0]` (the automated-sync variables are still false on this commit) and
nothing on the namespace or the Secret. If the plan still shows the destroy error, the `state rm`
did not land (wrong workspace, or a run re-created it); do not merge.

Production: re-run step 1's production plan only if the branch changed since; the expected output
is the same move-only plan.

### Step 4: merge the toggle, watch both workspaces

Merge the PR. The automated-sync commit (step 6) must not be part of this merge: revert it off the
branch first (`git revert <sha>`, push) and re-land it after step 5. If it was merged together with
the toggle anyway, nothing breaks (Terraform has already forgotten the release and ArgoCD never
reads Helm history), but the cheap rollback of section 6.2 then needs the flip reverted first, and
step 6's prune checks must still be done, just after the fact.

- `ac_app_staging_cluster_addons_layer`: plans 0 changes and finishes without an apply. Open the run
  and confirm it says exactly that.
- `ac_app_production_cluster_addons_layer`: plans the move, `0 to add, 0 to change, 0 to destroy`,
  and **waits for a confirm** because the move must be written to state. Confirm it promptly (the
  standing rule for production plans; this apply writes state and makes no cluster call, but if it
  fails with a credentials error, discard, re-plan and confirm immediately). Leaving it unconfirmed
  blocks later production runs. After the apply, production's state holds the release at
  `module.main_rails_app.helm_release.automation-calculator[0]`.
- `ac_app_development_cluster_addons_layer`: no cluster; the plan fails at `data.aws_eks_cluster`
  as before this PR.

The window is closed. Terraform no longer knows the staging release; ArgoCD is still on manual
sync; the app is untouched:

```bash
CANARY_APP=automation-calculator scripts/argocd_canary_check.sh | tee tmp/phase6-04-after-merge.txt
diff tmp/phase6-00-baseline.txt tmp/phase6-04-after-merge.txt      # only the Time: line
```

### Step 5: delete the Helm history, and only the Helm history

Helm stores each release revision as a Secret in the release namespace labelled
`owner=helm,name=<release>`. The app Secret `automation-calculator-app-secrets` carries
`app.kubernetes.io/*` labels only, so the selector cannot match it; prove that before deleting:

```bash
kubectl -n automation-calculator get secret -l owner=helm,name=automation-calculator
```

Expected: only `sh.helm.release.v1.automation-calculator.v<N>` entries, type
`helm.sh/release.v1`. If `automation-calculator-app-secrets` or anything else is listed, stop.

```bash
kubectl -n automation-calculator delete secret -l owner=helm,name=automation-calculator
helm -n automation-calculator list                                   # empty
kubectl -n automation-calculator get deploy,svc,ingress,secret       # all four still there
kubectl -n automation-calculator get pods -o wide                    # same pods as tmp/phase6-00-pods.txt
```

**Never run `helm uninstall automation-calculator`.** It deletes the Ingress, which deletes the
ALB, and external-dns can leave an orphaned TXT ownership record that blocks recreating the A
record. The release records are the only thing being removed here; the objects they describe stay.
The `meta.helm.sh/release-*` annotations and the `app.kubernetes.io/managed-by: Helm` label stay
on the live objects too; they are inert and let a manual `helm upgrade --install` re-adopt the
objects if that is ever needed (section 6.3).

This is the point of no return for the cheap rollback (section 6.2): from here on, the way back to
Terraform ownership is a Helm re-install, and the normal rollback of an app change is a git revert
synced by ArgoCD.

### Step 6: flip the staging Application to automated sync

Prune safety first. ArgoCD 3.x (what Phase 2 installs) tracks resources by the
`argocd.argoproj.io/tracking-id` annotation, not by the `app.kubernetes.io/instance` label. The
Terraform-managed Secret carries that label (it mirrors what Helm left) but no tracking
annotation, so prune ignores it. Confirm all three facts, then confirm nothing is marked for
pruning:

```bash
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.application\.resourceTrackingMethod}'; echo   # empty (default: annotation) or "annotation"; never "label"
kubectl -n automation-calculator get secret automation-calculator-app-secrets \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'; echo                     # empty
argocd app resources automation-calculator      # exactly: Service, Deployment, Ingress automation-calculator; no Secret, no Namespace
argocd app get automation-calculator            # Synced; no resource with "requires pruning" or "OutOfSync"
```

If `argocd app resources` lists the Secret, or `argocd app get` marks anything for pruning, do not
flip prune: understand why first (the Phase 4 and 5 runbooks describe the expected tracking state).

The flip is the second commit of the Phase 6 branch: in staging's `terraform.tfvars`,

```hcl
argocd_application_automated_sync = true
argocd_application_prune          = true
argocd_application_self_heal      = true
```

Land it as its own merge now (the follow-up PR; section 1 last bullet). Expected plans:
`ac_app_staging_cluster_addons_layer` **1 to change**, in place,
`module.argocd[0].helm_release.argocd_apps[0]` (`values`: the `syncPolicy.automated` block);
production and development 0 changes. The apply is `helm upgrade argocd-apps`, which patches the
Application CR; ArgoCD then reconciles immediately.

```bash
argocd app get automation-calculator            # Sync Policy: Automated (Prune), Self Heal: true; Synced; Healthy
kubectl -n argocd get application.argoproj.io automation-calculator -o jsonpath='{.spec.syncPolicy}'; echo
CANARY_APP=automation-calculator scripts/argocd_canary_check.sh | tee tmp/phase6-06-automated.txt
diff tmp/phase6-00-baseline.txt tmp/phase6-06-automated.txt   # Time: line and the Application block only
kubectl -n automation-calculator get deploy,svc,ingress,secret  # all four present: prune removed nothing
kubectl -n automation-calculator get pods -o wide               # same pods as step 0
curl -fsS https://staging.automation-calculations.io/health
```

Expected diff against the baseline: the Deployment `generation`, the Secret `resourceVersion`,
`data sha256` and `keys` identical; the same ALB hostname as step 0.

Finally `rm tmp/phase6-02-staging-state-before-rm.json` (it holds the state's secrets).

## 4. Expected TFC plans, per step

| Step | `ac_app_staging_cluster_addons_layer` | `ac_app_production_cluster_addons_layer` |
|---|---|---|
| 1, PR speculative plan, release still in state | **Error** `Instance cannot be destroyed` (prevent_destroy; the plan showed 1 to destroy). Do not merge. | moved `…automation-calculator` to `…[0]`; 0 / 0 / 0 |
| 3, after `state rm` | No changes | same as above |
| 4, toggle merge | 0 changes, planned and finished, no apply | moved; 0 / 0 / 0; **needs a confirm** to record the move |
| 6, automated-sync merge | 1 to change: `module.argocd[0].helm_release.argocd_apps[0]` in place | 0 changes |
| any later bump PR (Phase 7) | 0 changes: `values-staging.yaml` is no longer read by this workspace | 1 to change: the release, as today, until Phase 8 |

Development: no cluster; every plan fails at `data.aws_eks_cluster` as it did before this PR.

## 5. What the Terraform-managed objects do now

Staging's `module.main_rails_app` still owns the namespace, the Secret, RDS, the ACM certificate
and its validation records; `module.argocd[0]` owns ArgoCD and the Application. A change to the
Secret's data (a new OAuth value in TFC) is still a Terraform apply, and still takes effect on the
next rollout, which is now an ArgoCD sync (a bump PR) or a manual `kubectl -n automation-calculator
rollout restart deploy/automation-calculator`. The chart and `values-staging.yaml` are deployed by
ArgoCD only; the staging workspace still *queues* a run when they change (they are in
`cluster_addons_layer_module_directories` until Phase 9) but that run plans 0 changes.

## 6. Rollback

The app itself never changes in this phase, so there is nothing to roll back *for the app*. What
can need undoing is the hand-over.

### 6.1 Before step 4 (after the `state rm`, PR not merged)

Put the release back in state; the config on `main` has no `count` yet, so the address is
un-indexed:

```bash
cd terraform/env/staging/aws/us-west-1/cluster-addons-layer    # checkout on main
terraform import module.main_rails_app.helm_release.automation-calculator automation-calculator/automation-calculator
terraform plan                                                  # 0 changes
```

Then close or re-work the PR. (The helm provider imports a release as `<namespace>/<name>`; it
reads the Helm history, which is why step 5 comes after this point.)

### 6.2 After step 4, before step 5 (toggle merged, Helm history still present)

A plain revert of the toggle would plan `[0] will be created` and the apply would fail on
`cannot re-use a name that is still in use`. Import first, on the revert branch (its config has
`count = 1`, so the indexed instance exists):

```bash
git checkout -b revert-argocd-phase-6 main && git revert <toggle merge sha>
cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
terraform init
terraform import 'module.main_rails_app.helm_release.automation-calculator[0]' automation-calculator/automation-calculator
terraform plan                                                  # 0 changes
```

Merge the revert; staging plans 0 changes. If the automated-sync flip was already applied (section
6.3), the revert must include it (`argocd_application_automated_sync = false`) and must be applied
**before** the import, so ArgoCD is back on manual sync before Terraform manages the release again.

### 6.3 After step 5 (Helm history deleted)

There is no release to import. The way back to Terraform ownership is a manual Helm re-adoption,
which works because the live objects still carry Helm's `meta.helm.sh/release-*` annotations and
`managed-by: Helm` label:

```bash
argocd app set automation-calculator --sync-policy none       # stop automated sync first (Terraform re-applies the tfvars value on its next argocd_apps apply; revert the flip too)
helm -n automation-calculator upgrade --install automation-calculator helm/automation-calculator \
  -f helm/automation-calculator/values.yaml -f helm/automation-calculator/values-staging.yaml \
  --set ingress.certificateArn=<ACM ARN>                      # same values ArgoCD renders: no rollout
```

then section 6.2 (import `[0]`, revert the toggle). This path is for a broken ArgoCD, not for a bad
deploy: a bad deploy is a **git revert of the bump PR**, which ArgoCD syncs within its polling
interval (3 minutes by default; `argocd app sync automation-calculator` to hurry it).
`argocd app rollback` is refused while automated sync is on, by design.

What **not** to do, in any rollback: `helm uninstall automation-calculator`;
`argocd app delete` without `--cascade=false`; `kubectl delete namespace automation-calculator`;
removing `prevent_destroy` or the resource block to "make the plan go through".

## 7. Done when

- Staging state has no `helm_release.automation-calculator*`; the toggle merge planned 0 changes on
  staging; production confirmed the move-only run and its state holds
  `module.main_rails_app.helm_release.automation-calculator[0]`.
- `helm -n automation-calculator list` on staging is empty; the four objects, the pods, the ALB
  hostname, the Deployment `generation` and the Secret sha256 are unchanged from step 0.
- `argocd app get automation-calculator`: Automated (Prune), Self Heal, Synced, Healthy; health
  endpoint 200.
- A fresh speculative plan on both workspaces shows 0 changes.
- The state backup in `tmp/` is deleted. Phase 7 (a real bump through ArgoCD) can start.
