# ArgoCD migration Phase 8: production cutover

Companion to Phase 8 of `argocd-migration-plan.md`. Production gets what staging got in Phases 2,
5 and 6, in that order and on the same cluster objects: ArgoCD is installed by the
`ac_app_production_cluster_addons_layer` workspace together with the production `AppProject` and
`Application` (**Commit A**), the Application adopts the running app in place and is synced once
by hand, and then Terraform forgets the Helm release without destroying it (**Commit B**).
Production **stays on manual sync**: after this phase a production deploy is "merge the bump PR,
then `argocd app sync`". Nothing in the `automation-calculator` namespace is recreated or rolled at
any point; the only cluster writes are ArgoCD's tracking annotations and the deletion of Helm's
own history records. Those writes, the `argocd app sync` and the `terraform state rm` are the
user's to run with their own production identity: the `ac_app_production-ro` kube context is
read-only, and Claude Code sessions are denied production cluster writes. A Claude session can
run only part of the read-only checks alongside: the `_read_only` kube role reads pods,
Deployments, Ingresses and nodes (the preflight, the pod and YAML captures) and the alarm history,
but it cannot read Secrets or ArgoCD `Application` objects and cannot open the `argocd` CLI's
port-forward (seen on staging in Phases 6 and 7). So `helm list`, the Secret lines of
`scripts/argocd_canary_check.sh`, every `argocd` command and `scripts/argocd_staging_verify.sh`
need the user's own identity too.

The rules are the ones from Phases 5 and 6, with the production twist from the plan's Risks:

- **Nothing may touch the Ingress.** Deleting it deletes the ALB, and external-dns can leave an
  orphaned TXT record. No finalizer, no prune, no `helm uninstall`, `--cascade=false` on any
  delete.
- **Terraform must never plan a destroy of the release.** `prevent_destroy` turns the wrong order
  into a plan error; the fix is always the `state rm`, never removing the guard.
- **Two controllers must never reconcile the same Deployment.** The Application is manual, and
  `argocd app sync` is only run after `argocd app diff` has been read, until Commit B is applied.
- **Production applies on merge.** Since #477 (`docs/promotion.md`) the production cluster
  workspaces auto-apply: there is no confirm in Terraform Cloud, and the old risk of a plan-time
  EKS token expiring while a run waited is gone with it. The review is the speculative plan on
  each of the two PRs, read before the merge, and each merge needs the owner's explicit go-ahead.

## 1. What the PR changes

Two PRs, merged in this order, each one a production deploy on merge (`docs/promotion.md`):
**Commit A** is this PR (#386, branch `argocd-phase-8`) and **Commit B** is the PR stacked on it
(branch `argocd-phase-8-commit-b`). They were one branch until 2026-11-25; the names are kept
because the rest of this runbook uses them. **Commit B must not be merged before the `state rm`
of section 6**: merged early it is a plan error on production (harmless but blocking) or, with
the guard gone, an ALB deletion.

**Commit A, "install ArgoCD and the production Application":**

- `terraform/env/production/aws/us-west-1/cluster-addons-layer/terraform.tfvars`:
  `argocd_enabled = true`. Nothing else. The module defaults do the rest:
  `argocd_manage_application` defaults to `true` (the `argocd_apps` release renders the
  `AppProject` and `Application`), and `argocd_application_automated_sync`,
  `argocd_application_prune` and `argocd_application_self_heal` default to `false`, so the
  production Application has no `automated` block. Do not set any of the four in production's
  tfvars; automated sync on production is a separate decision (section 8).
- `scripts/argocd_staging_verify.sh`: `--expect-helm-release`, for the window between the two
  commits when Terraform still owns the release and `helm list` is legitimately non-empty; the
  manual-sync note is worded for production. The name is historical (Phase 7 wrote it for the
  staging soak); `--env production` has always selected `values-production.yaml`, and the
  production Application and Deployment have the same names as staging's, so no other flag is
  needed. It is not renamed here, so the Phase 7 runbook and the soak log keep pointing at it.
- This runbook, the plan's Phase 8 section, and the `AGENTS.md` script line.

**Commit B, "retire the Terraform release on production":**

- `terraform/env/production/aws/us-west-1/cluster-addons-layer/terraform.tfvars`:
  `manage_app_helm_release = false`.
- `AGENTS.md` (the tool-neutral half of `CLAUDE.md` since main's #437): production deploys read "merge the bump PR, then `argocd app sync`".
- `.claude/skills/deploy-image/SKILL.md` and `.claude/skills/validate-infra-rollout/SKILL.md`:
  production deploys by a manual `argocd app sync`, and a production snapshot has no app Helm
  release (added when `main` was merged into the stack on 2026-11-07, in a later commit than
  Commit B, but part of it).

Commit B was taken off the `argocd-phase-8` branch on 2026-11-25 (one commit that deletes the
`manage_app_helm_release = false` line and restores the production-on-TFC wording in `AGENTS.md`
and the two skills) and put back by its revert on `argocd-phase-8-commit-b`. That is how Phase 6
landed the automated-sync flip (its own PR, #464, merged after the staging Helm history was
deleted). Phase 9 (#387) stacks on the Commit B branch.

The Commit B PR's `Terraform Cloud/.../ac_app_production_cluster_addons_layer` status, when its
base is `main`, is red ("Terraform plan errored") until the `state rm`: the speculative plan
shows `1 to destroy` and then `Instance cannot be destroyed` on
`module.main_rails_app.helm_release.automation-calculator[0]`. That is the guard, not a build
failure. If Commit B is merged in that state by mistake, the production run errors the same way,
nothing is applied, and the fix is to run section 6 from step 2 and re-queue the run.

## 2. Gate: the staging soak

**Waived on the day count, 2026-11-25.** The owner started this phase with the gate at
`FAIL`: four clean bump cycles and the rollback test were recorded (three needed), but only one
day had passed since the first of them (three needed). The reason given was that staging had
taken a good number of deploys through ArgoCD without intervention. `status` therefore exits 1
below and that alone is not a stop; a failed cycle count, or a cycle with manual intervention,
still is.

```bash
git checkout main && git pull
scripts/argocd_soak_log.py status          # Gate: PASS as of <today>; exit 0
git diff --stat docs/argocd-staging-soak-log.md   # commit the refreshed Gate section if it changed
```

`status` applies the Phase 7 gate (at least three clean bump cycles and at least three days since
the first of them) and exits 1 on FAIL. Re-run it on the day the phase starts so the committed
log shows the evaluation date.

Also confirm staging is still in its Phase 7 state, logged in through the `argocd` CLI's own
port-forward (`argocd-phase-2-install.md` section 4.2):

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"
export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
argocd login --username admin              # staging password
scripts/argocd_staging_verify.sh           # Verify OK at the current values-staging.yaml tag
```

The CLI's port-forward goes to whatever cluster the current kubectl context points at, so check
`kubectl config current-context` before every `argocd` command from here on, and log in again
after every switch between staging and production: a production command must never be typed
against the staging API, and a login made on one cluster is not valid on the other.

## 3. Production preflight (the Phase 0 checks, on production)

Read-only. `scripts/infra_eng_sso.py up --environment production` writes the `infra-eng-production`
and `ac-ci-production` profiles, logs in, updates the `ac_app_production` kubeconfig entry and
switches the context (`docs/aws-sso-auth.md`).

```bash
eval "$(scripts/infra_eng_sso.py up --environment production)"
kubectl config current-context             # must be the ac_app_production cluster; everything below assumes it
mkdir -p tmp
scripts/argocd_preflight.sh | tee tmp/phase8-00-preflight.txt
```

**Pod headroom.** The Phase 0 table applies unchanged: one arm64 `t4g.medium` (since #410) allows 17 pods; ArgoCD adds
4 (controller, repo-server, server, redis; the ApplicationSet controller is scaled to 0); the
script fails when fewer than 4 slots would be left afterwards. Production on 2026-11-25: 11 pods (two app pods since #474, two ALB controller pods, Fluent Bit
since #470), so 6 free slots, 2 after ArgoCD, and one of those is used during a rollout
(`maxSurge 1`). Staging has run that same set since Phase 7.

**The ALB `replicaCount` reduction was not applied in Phase 0.** Staging had the headroom, so
`terraform/modules/aws/cluster-addons-layer/main.tf` still does not set `replicaCount` on
`helm_release.aws_load_balancer_controller` and the chart's default of 2 is what runs; the
preflight script prints the live count. If production's headroom is under 4, pick one of the two
Phase 0 options **in its own PR, applied and verified before Commit A**:

1. `replicaCount = 1` on the ALB controller (one freed slot at no cost: the second replica is a
   standby on a single node). It is a shared-module change, so it is a cluster-addons run on
   **both** staging (applied at merge) and production (applied by its promotion PR,
   `scripts/promote_to_production.sh addons`; it is a `helm upgrade` of the controller, no ALB
   change). Re-run `scripts/argocd_preflight.sh` on both afterwards.
2. `desired_size = 2` in `terraform/env/production/aws/us-west-1/base-cluster-layer/main.tf`. The
   production node group is already `desired_size = 1, max_size = 2, min_size = 1` (the env
   overrides the module default of `max_size = 1`), so this is one number, a base-cluster-layer run
   on production only, and a second instance's cost. It doubles the ceiling to 34 and is the choice
   when the shortfall is more than one slot. The base-layer apply queues a cluster-addons run
   through the run trigger; expect that run to plan 0 changes and let it finish. Every
   base-cluster-layer plan also carries the node group's AMI `release_version` bump (the module
   follows the newest AMI release), and applying it rolls the existing node: the single-node
   clusters showed an 85–88 s app outage on each node roll in 2026-11 (#409, #410). Schedule it
   like a node roll, not as a no-op.

**The release and the app are where Terraform left them:**

```bash
helm -n automation-calculator list                           # exactly one release, STATUS deployed
kubectl -n automation-calculator get deploy automation-calculator -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
yq -r '.image.tag' helm/automation-calculator/values-production.yaml   # same tag as the live image
scripts/argocd_canary_check.sh | tee tmp/phase8-00-baseline.txt       # the Real namespace block is the baseline for sections 5 and 6
kubectl -n automation-calculator get pods -o wide | tee tmp/phase8-00-pods.txt
kubectl -n automation-calculator get ingress automation-calculator -o yaml > tmp/phase8-00-ingress.yaml
kubectl -n automation-calculator get deploy automation-calculator -o yaml > tmp/phase8-00-deploy.yaml
kubectl -n automation-calculator get ingress automation-calculator -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo   # note the ALB hostname
```

If the live tag and `values-production.yaml` disagree, a production bump did not apply (an
errored or discarded run). Resolve that first: re-queue the run, or revert the values file. The
adoption in section 5 requires `main` and the cluster to render the same Deployment.

**The workspace is idle and has nothing waiting.** In the TFC UI,
`ac_app_production_cluster_addons_layer` has no run planning or applying, and its latest run
applied or planned no changes. Production applies shared code only when a production PR merges
(`docs/promotion.md`), so Commit A's plan also carries every module and chart change on `main`
that production has not applied yet. Promote those first (their own PR) so that Commit A's plan
is the four resources of 4.1 and nothing else.

**Tools:** `helm`, `argocd`, `yq`, `curl` on `PATH` (the preflight script checks the first two),
`TFE_TOKEN` exported for section 6, and the `argocd` CLI version at or above the server's
(`argocd version --client`; the server is v3.5.6 from the Phase 0 pin).

## 4. Commit A: install ArgoCD and the production Application

### 4.1 Expected plans

The plan to read is the speculative one Terraform Cloud posts on the PR (the
`ac_app_production_cluster_addons_layer` status). The same plan from the PR branch checkout, with
`TFE_TOKEN` set or a `terraform login` session (a speculative remote run; nothing is applied, and
no local AWS credentials are used):

```bash
cd terraform/env/production/aws/us-west-1/cluster-addons-layer
terraform init
terraform plan | tee ../../../../../../tmp/phase8-01-production-commit-a.txt
```

| Workspace | Expected plan for Commit A |
|---|---|
| `ac_app_production_cluster_addons_layer` | **4 to add**: `module.argocd[0].random_password.argocd_admin`, `module.argocd[0].time_static.argocd_admin_password`, `module.argocd[0].helm_release.argocd` and `module.argocd[0].helm_release.argocd_apps[0]`. 0 to change, 0 to destroy. **Applies on merge, no confirm.** |
| `ac_app_staging_cluster_addons_layer` | Not queued (production's tfvars directory is not one of its trigger prefixes); 0 changes if a run happens for another reason. |
| `ac_app_development_cluster_addons_layer` | No cluster; fails at `data.aws_eks_cluster` as before. |

**Stop and do not merge** if the production plan shows anything on `module.main_rails_app` (the
release, the namespace, the Secret, RDS, ACM), on `module.cluster_addons`, or an import: none of
that is this commit. The Phase 4 `import` blocks are gone (`imports_argocd_phase4.tf` was deleted
by #463 on 2026-11-19), so no import can legitimately appear. Two artifacts that older production plans showed are now
findings, not noise: a replacement of the ACM validation records (fixed by #404; it means a
module-level `depends_on` crept back onto `main_rails_app`) and a `1 to add` on
`aws_sns_topic_subscription.alarms_email` (fixed by #420).

### 4.2 Merge (the merge is the apply)

There is no admin password step before the merge: the `argocd` module generates production's own
password (`random_password.argocd_admin`, separate from staging's because each workspace has its
own state) in the same apply that installs ArgoCD. Commit A's plan carries its hash in
`helm_release.argocd` (shown as `(sensitive value)`), and the chart never creates
`argocd-initial-admin-secret` on production.

Merge the Commit A PR only once its speculative plan is the one in 4.1 and the owner has said
to merge it. The production run plans and applies by itself; watch it
(`python3 -I scripts/wait_commit_status.py` on the merge commit):

- The run's plan must again be the one in 4.1. `helm install argo-cd` runs with `wait = true`
  (up to 15 minutes, normally a few; about 5 on staging) and then `helm install argocd-apps`.
- If the apply fails with a credentials error (`the server has asked for the client to provide
  credentials`), the plan-time EKS token (15 minutes) expired, which now only happens when the
  run sat queued behind another workspace's run. The ArgoCD release stays on the cluster in
  whatever state it reached (`atomic = false`, `cleanup_on_fail = false`; see
  `argocd-phase-2-install.md` section 2). Inspect `helm -n argocd list` and
  `kubectl -n argocd get pods`, then queue a new run from the UI; it auto-applies and completes
  or repairs the install. Do not `helm uninstall argocd` by hand unless you are abandoning the
  install (Terraform would then point at a release that no longer exists).

### 4.3 Verify the install (Phase 2 section 3, on production)

```bash
kubectl -n argocd get pods                                      # four Running (controller-0, repo-server, server, redis) plus a Completed redis-secret-init job pod
kubectl -n argocd get deploy argocd-applicationset-controller   # READY 0/0
helm -n argocd list                                             # argocd and argocd-apps, both deployed
kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'; echo   # true
scripts/argocd_preflight.sh                                     # headroom now reflects ArgoCD's four pods; must still exit 0
```

First login, exactly as Phase 2 section 4.2, against the production context. The password is the
`argocd_admin_password` output of `ac_app_production_cluster_addons_layer` (Phase 2 section 4.1,
read with `terraform output` from the production `cluster-addons-layer` directory). The CLI uses
its own port-forward; do not point it at a `kubectl port-forward`:

```bash
kubectl config current-context                                  # ac_app_production
kubectl -n argocd get secret argocd-initial-admin-secret       # NotFound: Terraform set the password
export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
argocd version                                                  # needs no login; server v3.5.6
argocd login --username admin                                   # the production password
```

If the Secret exists, the install did not receive the generated hash; stop and read the run's plan
for `helm_release.argocd` before going on.

The CLI's port-forward follows the current kubectl context, and a login made on staging is not
valid on production (or the reverse). After every context switch, check
`kubectl config current-context` and run `argocd login --username admin` again with that
environment's password.

## 5. Adopt the production app in place (the Phase 5 checks)

Everything in `argocd-phase-5-adopt-application.md` sections 4 to 6 applies verbatim, with the
production context and `tmp/phase8-*` file names. The short form:

### 5.1 Before the first sync

```bash
argocd proj get automation-calculator       # sources: this repo; destinations: automation-calculator only
argocd app get automation-calculator        # Project automation-calculator, Sync OutOfSync, Health Healthy, Sync Policy Manual
kubectl -n argocd get application.argoproj.io automation-calculator -o jsonpath='{.metadata.finalizers}'; echo   # empty
kubectl -n argocd get application.argoproj.io automation-calculator -o jsonpath='{.spec.syncPolicy}'; echo       # {"syncOptions":["CreateNamespace=true"]}; no "automated"
argocd app manifests automation-calculator | yq -N '[.kind, .metadata.name] | join(" ")'   # Service, Deployment, Ingress automation-calculator; nothing else
argocd app diff automation-calculator | tee tmp/phase8-02-diff.txt   # exits 1: there is a diff
scripts/argocd_staging_verify.sh --env production --expect-helm-release | tee tmp/phase8-02-verify-before-sync.txt
```

The finalizer must be empty and the sync policy must have no `automated` key; stop if either is
wrong, the module rendered something it should not have.

The diff must be, for each of the three objects, exactly one added annotation
`argocd.argoproj.io/tracking-id`, and nothing under `spec`. Phase 5 section 4 lists what a `spec`
line means (a pending bump, a wrong release name, an ALB annotation change) and why each one
means **do not sync**.

The verify run is expected to fail on exactly one line, `Application sync status is OutOfSync,
expected Synced`: the tracking annotation is missing until the sync. Everything else (Deployment
tag and rollout, newest pod tag and `SHORT_COMMIT_HASH`, `/health`, Helm release present) must
pass. Keep the transcript.

### 5.2 First sync

```bash
argocd app sync automation-calculator --timeout 300
argocd app get automation-calculator        # Synced, Healthy
argocd app history automation-calculator    # ID 0 at the current main SHA
```

The sync applies the three manifests; since nothing under `spec` differed, the only writes are the
tracking annotation and `kubectl.kubernetes.io/last-applied-configuration`. No new ReplicaSet, no
new pod, no Ingress change.

### 5.3 After the first sync

```bash
scripts/argocd_canary_check.sh | tee tmp/phase8-03-synced.txt
diff tmp/phase8-00-baseline.txt tmp/phase8-03-synced.txt    # Deployment and Ingress resourceVersion, Deployment generation up by one (annotations bump it; seen on staging in Phase 5), the Time: line; Secret lines identical
kubectl -n automation-calculator get deploy automation-calculator -o yaml > tmp/phase8-03-deploy.yaml
kubectl -n automation-calculator get ingress automation-calculator -o yaml > tmp/phase8-03-ingress.yaml
diff tmp/phase8-00-deploy.yaml tmp/phase8-03-deploy.yaml    # annotations, resourceVersion, a managedFields entry for argocd-controller, metadata.generation and status.observedGeneration up by one; nothing under spec
diff tmp/phase8-00-ingress.yaml tmp/phase8-03-ingress.yaml  # same
kubectl -n automation-calculator get pods -o wide            # same pod names, AGE and RESTARTS as tmp/phase8-00-pods.txt
kubectl -n automation-calculator get ingress automation-calculator -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo   # same ALB hostname as section 3
helm -n automation-calculator status automation-calculator  # deployed, same REVISION as before
scripts/argocd_staging_verify.sh --env production --expect-helm-release | tee tmp/phase8-03-verify-after-sync.txt   # Verify OK; last operation started by user admin (manual sync)
```

Then a fresh speculative production plan (4.1's command) must show **0 changes**: the Helm
provider never reads live objects, so the annotations are invisible to it.

Production is the one environment with CloudWatch alarms (`ac-app-production-*`, including the
unhealthy-hosts alarm that #425 tied to the app's target group through the Ingress's
`ingress.k8s.aws/stack` tag). Adoption touches no pod and no target, so the expectation from the
section 3 baseline time to now is **no transition** at all. Read the history (the
`validate-infra-rollout` skill's alarm facts explain why `describe-alarm-history`, not
`StateReason`, is the authority):

```bash
aws cloudwatch describe-alarm-history --region us-west-1 --profile ac-ci-staging-ro \
  --start-date <section 3 UTC> --end-date <now UTC> --max-records 100 --output text \
  --query 'AlarmHistoryItems[?starts_with(AlarmName,`ac-app-production`)].[Timestamp,HistoryItemType,AlarmName,HistorySummary]'
AWS_PROFILE=ac-ci-staging-ro python3 -I scripts/alb_alarm_window.py --env production --start <section 3 UTC> --end <now UTC>
```

Repeat the same read after Commit B (section 6, step 5) over its window.

Production is now in the Phase 5 end state: two controllers know about the app, ArgoCD on manual
sync. **A production bump PR merged from here until section 6 step 4 is applied by Terraform**
(the production run, auto-applied, as today), after which ArgoCD shows `OutOfSync` on the pod
template until someone syncs it (Phase 5 section 8). Avoid it: do not merge production PRs
between Commit A and Commit B, and keep the gap short (same day is fine; the adoption checks take
under an hour). Staging bump PRs change no production file and are safe to merge throughout.

## 6. Commit B: retire the Terraform release on production

This is `argocd-phase-6-retire-staging-release.md` section 3 against the production workspace,
with one difference that matters: **the state address is indexed.** Production applied the Phase 6
PR with `manage_app_helm_release = true`, so its run recorded the `moved` block and its state holds
the release at `module.main_rails_app.helm_release.automation-calculator[0]`. (Staging ran the
`state rm` before applying that PR, which is why its runbook used the un-indexed address.) Quote
the brackets in zsh.

Run steps 1 to 5 in one sitting, in this order, with the Commit B PR reviewed and approved
before step 2, and no other merge touching the production addons workspace between step 2 and
step 4. Production auto-applies, like staging did in Phase 6: the merge in step 4 plans 0 changes
and finishes on its own, and any other production run inside the window applies without asking.

### Step 0: pre-checks

Section 5.3 holds: Application Synced, Healthy, manual; `argocd app diff` empty (exit 0); fresh
production plan 0 changes; the workspace idle; `helm -n automation-calculator list` shows the one
release. Re-take the baseline if anything was deployed since:

```bash
scripts/argocd_canary_check.sh | tee tmp/phase8-04-baseline.txt
kubectl -n automation-calculator get pods -o wide | tee tmp/phase8-04-pods.txt
argocd app get automation-calculator        # Synced, Healthy, Sync Policy: Manual
argocd app diff automation-calculator       # no output, exit 0
```

### Step 1: the speculative plan before the `state rm` (what "wrong" looks like)

From the Commit B branch (`argocd-phase-8-commit-b`), after Commit A has merged and the branch
has been brought up to `main`:

```bash
cd terraform/env/production/aws/us-west-1/cluster-addons-layer
terraform init
terraform plan | tee ../../../../../../tmp/phase8-05-production-before-rm.txt
```

Expected: the plan shows `module.main_rails_app.helm_release.automation-calculator[0] will be
destroyed (because index [0] is out of range for count)`, then **errors** with `Instance cannot be
destroyed` because of `prevent_destroy`. That is the guard working. **Commit B must not be merged
while the plan looks like this**; the fix is step 2, never the guard. (TFC's speculative run on
the PR shows the same error.)

### Step 2: forget the release in the production workspace

```bash
cd terraform/env/production/aws/us-west-1/cluster-addons-layer
terraform state list | grep helm_release          # module.main_rails_app.helm_release.automation-calculator[0]
terraform state pull > ../../../../../../tmp/phase8-06-production-state-before-rm.json   # backup; holds secrets, delete it in step 5
terraform state rm 'module.main_rails_app.helm_release.automation-calculator[0]'
terraform state list | grep helm_release          # nothing
```

`state rm` takes the workspace lock and writes a new state version (States tab in the TFC UI). It
fails if a run holds the lock: wait for the run, never force-unlock. It does not touch the cluster:
`helm -n automation-calculator list` still shows the release; the pods, the Ingress and the ALB are
as in step 0. If `state list` shows the un-indexed address instead, production did not apply the
Phase 6 move; `state rm` that address instead and note it in the PR.

From here until step 4 completes the window of Phase 6 section 2 is open: a production run in it
would plan `helm_release.automation-calculator[0] will be created` and, with nobody to stop it,
start applying and fail on `cannot re-use a name that is still in use` because the Helm history
still exists. It fails safe; still, merge nothing else and queue no run by hand.

### Step 3: the speculative plan after the `state rm`

```bash
terraform plan | tee ../../../../../../tmp/phase8-07-production-after-rm.txt
```

Expected: `No changes. Your infrastructure matches the configuration.` Nothing on
`module.argocd[0]`, nothing on the namespace or the Secret. If the destroy error is still there,
the `state rm` did not land (wrong workspace?); do not merge.

### Step 4: merge Commit B

Merge the Commit B PR (re-run its speculative plan first if step 3 was read from a local plan:
the PR status must be green and say no changes). Expected runs:

- `ac_app_production_cluster_addons_layer`: `Plan: 0 to add, 0 to change, 0 to destroy`, planned
  and finished, no apply. Open the run and check it says exactly that.
- `ac_app_staging_cluster_addons_layer`: not queued (production's tfvars directory is not one of
  its trigger prefixes); 0 changes if a run happens for another reason.
- Development: no cluster; fails at `data.aws_eks_cluster` as before.

The window is closed: Terraform no longer knows the production release, ArgoCD is on manual sync,
the app is untouched:

```bash
scripts/argocd_canary_check.sh | tee tmp/phase8-08-after-merge.txt
diff tmp/phase8-04-baseline.txt tmp/phase8-08-after-merge.txt   # only the Time: line
```

### Step 5: delete the Helm history, and only the Helm history

```bash
kubectl -n automation-calculator get secret -l owner=helm,name=automation-calculator   # only sh.helm.release.v1.automation-calculator.v<N>, type helm.sh/release.v1
```

If `automation-calculator-app-secrets` or anything else is listed, stop (the selector cannot match
it: the app Secret carries `app.kubernetes.io/*` labels only).

```bash
kubectl -n automation-calculator delete secret -l owner=helm,name=automation-calculator
helm -n automation-calculator list                                   # empty
kubectl -n automation-calculator get deploy,svc,ingress,secret       # all four still there
kubectl -n automation-calculator get pods -o wide                    # same pods as tmp/phase8-04-pods.txt
scripts/argocd_staging_verify.sh --env production | tee tmp/phase8-09-verify.txt   # Verify OK, no --expect-helm-release any more
rm tmp/phase8-06-production-state-before-rm.json                     # the state backup holds secrets
```

**Never run `helm uninstall automation-calculator`.** It deletes the Ingress, which deletes the
ALB. Only the release records are removed; the objects they describe stay, with their inert
`meta.helm.sh/release-*` annotations and `managed-by: Helm` label (which is what lets section 9.5
re-adopt them if ever needed).

This is the point of no return for the cheap rollback (section 9.4). From here, the way back to
Terraform ownership is a Helm re-install, and the rollback of a bad deploy is a git revert or an
`argocd app rollback` (section 8).

## 7. Expected TFC plans, per step

| Step | `ac_app_production_cluster_addons_layer` | `ac_app_staging_cluster_addons_layer` |
|---|---|---|
| Commit A, speculative and merge | 4 to add: `module.argocd[0].random_password.argocd_admin`, `module.argocd[0].time_static.argocd_admin_password`, `module.argocd[0].helm_release.argocd`, `module.argocd[0].helm_release.argocd_apps[0]`; **applies on merge** | not queued / 0 changes |
| after the first sync (5.3) | 0 changes | 0 changes |
| Commit B speculative, release still in state (6, step 1) | **Error** `Instance cannot be destroyed` (prevent_destroy; the plan showed 1 to destroy). Do not merge. | n/a |
| after `state rm` (6, step 3) | No changes | n/a |
| Commit B merge (6, step 4) | 0 changes, planned and finished, no apply | not queued / 0 changes |
| any later production bump PR | 0 changes (`values-production.yaml` is no longer read by this workspace); the run is still queued until Phase 9 removes `values-production.yaml` from production's trigger patterns | not queued |
| any later `argocd_application_*` change in production tfvars (section 8, if ever) | 1 to change: `module.argocd[0].helm_release.argocd_apps[0]` in place | 0 changes |

Development: no cluster; every plan fails at `data.aws_eks_cluster` as before this phase.

## 8. The production deploy from now on

Production stays on **manual sync**. `main` is still the single source of truth, but nothing
reaches the production cluster until a human runs the sync. A deploy is still two PRs
(`docs/promotion.md`): the staging bump PR, which ArgoCD rolls out on staging by itself, and,
once staging is verified, the production bump PR, which changes `values-production.yaml` only.
Merging the production PR no longer deploys by itself (the production TFC run it queues plans 0
changes); the sync is the deploy. That puts back a manual step that #477 removed when it made the
merge of the production PR the deploy; automated sync on production (end of this section) would
restore "merge is the deploy".

```bash
# 1. Merge the production bump PR (scripts/bump_app_docker_image_version_branch.sh TAG SHA
#    production), after the staging bump PR is merged and verified on staging. The production
#    TFC run plans 0 changes and needs nothing.

# 2. Production: SSO to the ac_ci_terraform_production role (docs/aws-sso-auth.md), log in
#    through the argocd CLI's own port-forward (not kubectl port-forward).
eval "$(scripts/infra_eng_sso.py up --environment production)"
kubectl config current-context                                   # ac_app_production
export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
argocd login --username admin                                    # the production password

# 3. Look before syncing. --refresh re-reads main now instead of at the next poll.
argocd app get automation-calculator --refresh                   # OutOfSync on the Deployment
argocd app diff automation-calculator                            # exactly: the image tag and the SHORT_COMMIT_HASH value

# 4. Sync, then watch the rollout (startup probe: up to 3 minutes; the old pod keeps serving).
argocd app sync automation-calculator --timeout 600
kubectl -n automation-calculator rollout status deploy/automation-calculator
argocd app get automation-calculator                             # Synced, Healthy

# 5. Verify from the merged main.
git checkout main && git pull
scripts/argocd_staging_verify.sh --env production                # Verify OK at the new tag; last operation started by user admin
```

Anything in the diff other than the tag and the hash (an Ingress annotation, a selector, a probe)
is a chart change riding along with the bump; understand it before syncing, since on production
there is no second look after the sync.

**Rolling back a bad production deploy.** Two ways, in order of preference:

1. A revert PR of the bump (Phase 7 section 4), merged, then steps 2 to 5 above. `main` and the
   cluster agree afterwards.
2. `argocd app rollback automation-calculator <ID>` (an earlier `argocd app history` ID). It works
   on production because sync is manual, and it is immediate. But `main` is then ahead of the
   cluster: the next `argocd app sync` would deploy the bad tag again. Follow it with the revert PR
   anyway, and do not sync until that is merged.

**Moving production to automated sync** is a separate decision, not part of this phase. It would be
`argocd_application_automated_sync = true` (with `prune` and `self_heal`) in production's tfvars,
one in-place change to `module.argocd[0].helm_release.argocd_apps[0]`, after the Phase 6 step 6
prune checks on production (`argocd app resources` lists only the Service, Deployment and Ingress;
the Secret has no tracking annotation). It makes PR review the only gate for production and takes
`argocd app rollback` away. Leave it off until that trade has been decided on its own.

## 9. Rollback

The app never changes in this phase, so there is nothing to roll back *for the app*. What can need
undoing is the hand-over, and the cheap way back depends on how far it got.

### 9.1 After Commit A, before the first sync

Terraform's release owns everything; the Application is a second observer that has written
nothing. Through a PR, either `argocd_manage_application = false` in production's tfvars (1 to
destroy, `module.argocd[0].helm_release.argocd_apps[0]`; the two CRs are uninstalled; no finalizer,
so nothing cascades) or `argocd_enabled = false` (4 to destroy, the four resources Commit A added;
the `argocd` namespace goes with them, the CRDs stay). Either applies when its PR merges. By hand, right now:
`argocd app delete automation-calculator --cascade=false -y`, then the tfvars PR. **Never omit
`--cascade=false`**, and in the UI only "Non-cascading" is safe (Phase 5 section 7).

### 9.2 After the first sync, before the `state rm`

Same as 9.1. The tracking annotations stay on the three objects; they are harmless and ArgoCD
re-adopts them when the Application comes back.

### 9.3 After the `state rm`, Commit B not merged

Put the release back in state. Production's configuration on `main` already has `count`, so the
indexed address is the one to import (this differs from Phase 6 section 6.1, where staging's
`main` had no `count` yet):

```bash
cd terraform/env/production/aws/us-west-1/cluster-addons-layer    # checkout on main
terraform init
terraform import 'module.main_rails_app.helm_release.automation-calculator[0]' automation-calculator/automation-calculator
terraform plan                                                    # 0 changes
```

Then close or re-work the PR. The import reads the Helm history, which is why step 5 of section 6
comes after this point.

### 9.4 After Commit B is merged, Helm history still present

A plain revert of Commit B would plan `[0] will be created` and the apply would fail on
`cannot re-use a name that is still in use`. Import first, on the revert branch:

```bash
git checkout -b revert-argocd-phase-8-commit-b main && git revert <Commit B merge sha>
cd terraform/env/production/aws/us-west-1/cluster-addons-layer
terraform init
terraform import 'module.main_rails_app.helm_release.automation-calculator[0]' automation-calculator/automation-calculator
terraform plan                                                    # 0 changes
```

Merge the revert; production plans 0 changes. ArgoCD was never automated on production, so there
is no sync policy to turn off first.

### 9.5 After the Helm history is deleted

There is no release to import. The way back to Terraform ownership is a manual Helm re-adoption
(the live objects still carry Helm's `meta.helm.sh/release-*` annotations and `managed-by: Helm`
label), followed by 9.4:

```bash
helm -n automation-calculator upgrade --install automation-calculator helm/automation-calculator \
  -f helm/automation-calculator/values.yaml -f helm/automation-calculator/values-production.yaml \
  --set ingress.certificateArn=<ACM ARN>                           # the values ArgoCD renders: no rollout
```

This path is for a broken ArgoCD, not for a bad deploy; a bad deploy is section 8.

What **not** to do, in any rollback: `helm uninstall automation-calculator`; `argocd app delete`
without `--cascade=false`; `kubectl delete namespace automation-calculator`; removing
`prevent_destroy` or the resource block to "make the plan go through"; merging a production PR
whose speculative plan has not been read.

## 10. Done when

- `scripts/argocd_soak_log.py status` passed its cycle count on the day the phase started (the
  day count was waived by the owner on 2026-11-25, section 2), and the preflight exited 0 on
  production.
- Commit A applied on production with exactly 4 resources added; `kubectl -n argocd get pods`
  shows the four pods; `argocd login` works with the workspace output `argocd_admin_password`, and
  `argocd-initial-admin-secret` does not exist.
- The section 5.1 diff showed only the tracking annotation; the 5.3 diffs show only annotations,
  `managedFields` and the Deployment `generation` up by one; Deployment `.spec` and rollout
  revision, Secret `resourceVersion` and sha256 unchanged;
  same pods, same ALB hostname; `/health` 200; `argocd app history` shows ID 0 at the `main` SHA.
- Production state has no `helm_release.automation-calculator*`; Commit B's merge planned 0
  changes; `helm -n automation-calculator list` is empty; the four objects, the pods, the ALB
  hostname, the Deployment `generation` and the Secret sha256 are unchanged from the section 6
  baseline; the state backup in `tmp/` is deleted.
- `scripts/argocd_staging_verify.sh --env production` prints `Verify OK` with no flags.
- `argocd app get automation-calculator` on production: Sync Policy Manual, Synced, Healthy; a
  fresh production plan shows 0 changes; `AGENTS.md` says production deploys are "merge, then
  `argocd app sync`".
- Phase 9 (decommission the release from the module, drop the chart from the TFC triggers) can
  start.
