# ArgoCD migration Phase 3: dry run on a scratch copy (staging)

Companion to Phase 3 of `argocd-migration-plan.md`. Learn ArgoCD on a copy of the app that cannot
touch the ALB or the real database: an `Application` named `ac-canary` in its own `scratch` project,
deploying this repo's chart into a throwaway `argocd-canary` namespace. Everything is done through
`kubectl` and the `argocd` CLI; Terraform is not involved and nothing here changes it.

The two manifests live in `argocd/scratch/` and are applied by hand:

| File | Object | What it fences |
|---|---|---|
| `argocd/scratch/appproject.yaml` | `AppProject` `scratch` | Source: this repository only. Destination: namespace `argocd-canary` on the local cluster only. Cluster-scoped kinds: only the `argocd-canary` `Namespace` (needed for `CreateNamespace=true`; see below). |
| `argocd/scratch/application.yaml` | `Application` `ac-canary` | Chart `helm/automation-calculator` at `main` with `values.yaml` + `values-staging.yaml`, release name `ac-canary`, `fullnameOverride=ac-canary`, `ingress.enabled=false`, a chart-rendered Secret named `ac-canary-app-secrets` built from dummy values, manual sync, `CreateNamespace=true`, **with** the `resources-finalizer`. |

The real Application in Phase 5 is deliberately different: no finalizer (it would cascade-delete the
Ingress and therefore the ALB) and release name `automation-calculator`.

## Design notes (why the manifests look the way they do)

- **`fullnameOverride`** exists in the chart (`values.yaml` pins it to `automation-calculator`;
  `templates/_helpers.tpl` honours it), so the canary's Deployment and Service are named
  `ac-canary`. The release name feeds `app.kubernetes.io/instance` in the Deployment selector, so
  `releaseName: ac-canary` means the canary's Service can never select the real pods.
- **`ingress.enabled=false`**: the render contains no Ingress. Never enable it on the canary:
  `values-staging.yaml` carries the real ALB name (`ac-app-staging`), so a second Ingress would
  fight the real one for the ALB.
- **Dummy secrets.** `templates/secret.yaml` wraps every key in `required`, so each of
  `secrets.databaseUrl`, `githubOAuthAppId`, `githubOAuthAppSecret`, `googleOAuthAppId`,
  `googleOAuthAppSecret` and `secretKeyBase` gets a placeholder parameter. The Secret is renamed to
  `ac-canary-app-secrets` (`secrets.kubernetesSecretObjectName`) so that even a mistaken destination
  could not overwrite `automation-calculator-app-secrets`. The database URL points at nothing, so the
  canary pod **never becomes Ready**: `/health` runs `SELECT 1`, the startup probe gives up after 3
  minutes, and the Deployment reports `Progressing` and then `Degraded` (after the 10-minute
  progress deadline). That is expected. The exercise is about sync mechanics, not app health, so
  never use `argocd app wait --health` here; `argocd app sync` only waits for the operation.
- **`CreateNamespace=true` and the AppProject.** gitops-engine appends the namespace as a PreSync
  task and runs it through the project's permission check together with every other task, so an
  `AppProject` with an empty `clusterResourceWhitelist` fails the first sync with
  `resource :Namespace is not permitted in project scratch`. The whitelist therefore allows exactly
  one cluster-scoped kind, `Namespace`, narrowed by name to `argocd-canary`. The created namespace
  carries no ArgoCD tracking metadata (the sync-options docs: "the generated namespace is normally
  not tracked with Argo CD"), so the finalizer does not delete it; section 10 deletes it by hand.
- **`helm.sh/resource-policy: keep`** on the chart's Secret is mapped by ArgoCD to
  `argocd.argoproj.io/sync-options: Delete=false`, not `Prune=false`. So the canary Secret survives
  `argocd app delete` (section 10) but is removed by `argocd app sync --prune` (section 9).
- **Manual sync** because `argocd app rollback` is refused while automated sync is on, and because
  every step below is an explicit `argocd app sync` whose diff is inspected first.
- Local proof, no cluster needed: `helm template ac-canary helm/automation-calculator -n
  argocd-canary --values ... --set <every parameter above>` renders exactly a Secret
  (`ac-canary-app-secrets`), a Service (`ac-canary`) and a Deployment (`ac-canary`), no Ingress and
  no `namespace:` field on any object.

## 0. Before you start

- Phase 2 is done on staging: ArgoCD pods Running, `argocd login` works, admin password rotated.
- Tools: `kubectl`, `argocd`, `helm`, `yq`, `git`.
- Pod headroom: the canary adds one pod, two during a rollout (`maxSurge` 25% rounds up to 1).

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # SSO login, kubeconfig, AWS_PROFILE
kubectl config current-context                                # must be the ac_app_staging cluster
ARGOCD_PODS=2 scripts/argocd_preflight.sh                     # headroom for the canary (ArgoCD is already counted)
```

Port-forward and log in, as in `argocd-phase-2-install.md`. In one terminal:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

In another:

```bash
argocd login localhost:8080 --username admin --plaintext
argocd app list                                            # empty
argocd proj list                                           # default only
```

## 1. Baseline of the real namespace

`scripts/argocd_canary_check.sh` is read-only (`kubectl get` only). It prints, for the real
`automation-calculator` namespace, the Deployment generation / observedGeneration / image /
resourceVersion, the Ingress resourceVersion and the Secret resourceVersion plus a sha256 over its
data; then the contents of `argocd-canary` and the canary Application's status.

```bash
mkdir -p tmp
scripts/argocd_canary_check.sh | tee tmp/canary-00-baseline.txt
```

Run it after **every** step below and compare the "Real namespace" block against the baseline:

```bash
scripts/argocd_canary_check.sh | tee tmp/canary-NN-<step>.txt
diff <(sed -n '/^Real namespace/,/^$/p' tmp/canary-00-baseline.txt) \
     <(sed -n '/^Real namespace/,/^$/p' tmp/canary-NN-<step>.txt) && echo "real namespace unchanged"
```

Any difference in that block means something touched the real app. Stop, go to section 11, and
find out what before continuing. (A Deployment `resourceVersion` can legitimately change if a pod
restarts and the status is updated; `generation` and the Secret sha256 must never change.)

## 2. Create the project and the Application

```bash
kubectl apply -f argocd/scratch/appproject.yaml
kubectl apply -f argocd/scratch/application.yaml
argocd proj get scratch
argocd app get ac-canary          # Sync Status: OutOfSync, Health: Missing; nothing created yet
```

The manifests say `targetRevision: main`, so the Application reads the chart as merged on `main`,
not from your checkout. Nothing is deployed until the first sync.

## 3. Inspect the diff, then sync

```bash
argocd app diff ac-canary          # exit 1 and a full "+" diff: the Secret, Service and Deployment
argocd app manifests ac-canary | yq -N '[.kind, .metadata.name] | join(" ")'
```

Expected manifests: `Secret ac-canary-app-secrets`, `Service ac-canary`, `Deployment ac-canary`.
No Ingress, nothing named `automation-calculator`. If the list differs, do not sync.

```bash
argocd app sync ac-canary --timeout 300
argocd app get ac-canary           # Sync Status: Synced; Health: Progressing (later Degraded, expected)
argocd app history ac-canary       # ID 0, revision = current main SHA
```

If the sync fails with `resource :Namespace is not permitted in project scratch`, the
`clusterResourceWhitelist` in `appproject.yaml` was not applied; re-apply it and sync again.

## 4. Verify the canary namespace

```bash
kubectl get namespace argocd-canary
kubectl -n argocd-canary get deploy,svc,secret,pods -o wide
kubectl -n argocd-canary get deploy ac-canary -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl -n argocd-canary get ingress      # No resources found
```

Expected: one `ac-canary` pod (Running but not Ready, or CrashLoopBackOff, because of the dummy
database URL), Service `ac-canary` of type NodePort, Secret `ac-canary-app-secrets`. If the pod is
`Pending` with `Insufficient cpu` or `Insufficient memory`, shrink the canary's requests (this does
not touch the chart or the real app):

```bash
argocd app set ac-canary -p resources.requests.cpu=100m -p resources.requests.memory=256Mi
argocd app sync ac-canary --timeout 300
```

Then the untouched check: `scripts/argocd_canary_check.sh | tee tmp/canary-04-synced.txt` and the
`diff` from section 1.

## 5. Bump `image.tag` on a branch

The bump happens in git, on a branch that is **never merged**. Pick a tag that exists on Docker Hub,
for example one that staging ran before (`git log -p origin/main --
terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars | grep '^-app_version'`
lists retired values; `0.9.6-698` was one).

```bash
git fetch origin
git checkout -b argocd-canary-bump origin/main
yq -i '.image.tag = "0.9.6-698"' helm/automation-calculator/values-staging.yaml
git diff                                            # exactly one line
git commit -am "ArgoCD Phase 3: canary image bump (never merge)"
git push -u origin argocd-canary-bump
```

Only `values-staging.yaml` changes because that is the only values file the canary reads. Do not
open a PR for this branch and do not merge it; it is deleted in section 10.

## 6. Point the Application at the branch and sync

```bash
argocd app set ac-canary --revision argocd-canary-bump
argocd app get ac-canary                            # OutOfSync
argocd app diff ac-canary                           # only the Deployment image line changes
argocd app sync ac-canary --timeout 300
kubectl -n argocd-canary get deploy ac-canary -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
argocd app history ac-canary                        # ID 0 (main) and ID 1 (argocd-canary-bump)
```

`argocd app set` edits the live `Application` object; `kubectl apply -f argocd/scratch/application.yaml`
puts it back to the file at any time.

Untouched check: `scripts/argocd_canary_check.sh | tee tmp/canary-06-branch.txt` and `diff`.

## 7. Roll back

Automated sync is off, so rollback is allowed:

```bash
argocd app rollback ac-canary 0 --timeout 300
kubectl -n argocd-canary get deploy ac-canary -o jsonpath='{.spec.template.spec.containers[0].image}'; echo   # the main tag again
argocd app get ac-canary                            # OutOfSync: the spec still targets the branch
argocd app history ac-canary                        # ID 2, revision = the main SHA from ID 0
```

Rollback redeploys the manifests of history entry 0; the Application's `targetRevision` still says
`argocd-canary-bump`, so ArgoCD reports OutOfSync. That is what rollback looks like in production
too (Phase 8 keeps manual sync): the fix is in git, then sync. Here, point it back at `main`:

```bash
argocd app set ac-canary --revision main
argocd app get ac-canary                            # Synced (OutOfSync only if main moved meanwhile; then sync)
```

Untouched check: `scripts/argocd_canary_check.sh | tee tmp/canary-07-rollback.txt` and `diff`.

## 8. Rollback refusal with automated sync (optional, two commands)

To see the guard the plan relies on in Phase 7:

```bash
argocd app set ac-canary --sync-policy automated
argocd app rollback ac-canary 0                     # refused: the API rejects rollback while auto-sync is enabled
argocd app set ac-canary --sync-policy manual
argocd app get ac-canary | grep -i 'sync policy'    # Manual
```

Leave it on manual: the prune and delete steps assume it.

## 9. Prune

Drop the Secret from the render and watch ArgoCD refuse to delete it until told to:

```bash
argocd app set ac-canary -p secrets.create=false
argocd app diff ac-canary                           # the Secret is marked for deletion
argocd app sync ac-canary --timeout 300             # Secret listed as "ignored (requires pruning)"
argocd app get ac-canary                            # OutOfSync
kubectl -n argocd-canary get secret ac-canary-app-secrets   # still there
argocd app sync ac-canary --prune --timeout 300
kubectl -n argocd-canary get secret ac-canary-app-secrets   # NotFound
argocd app get ac-canary                            # Synced
```

The canary Secret carries `helm.sh/resource-policy: keep`, which ArgoCD reads as `Delete=false`,
not `Prune=false`: it is pruned. In Phase 6 the real Secret is safe from prune for a different reason:
once Terraform manages it, it carries no ArgoCD tracking annotation, so ArgoCD never considers it
part of the Application.

Put the Secret back so the delete step exercises it:

```bash
argocd app set ac-canary -p secrets.create=true
argocd app sync ac-canary --timeout 300
kubectl -n argocd-canary get secret ac-canary-app-secrets   # back
```

Untouched check: `scripts/argocd_canary_check.sh | tee tmp/canary-09-prune.txt` and `diff`. The
real `automation-calculator-app-secrets` must have the same resourceVersion and sha256 as in the
baseline.

## 10. Delete, and clean up what the finalizer leaves behind

```bash
argocd app delete ac-canary --wait -y               # cascade (default): the finalizer deletes the managed resources
kubectl -n argocd get application.argoproj.io ac-canary   # NotFound
kubectl -n argocd-canary get deploy,svc,pods        # No resources found
kubectl -n argocd-canary get secret                 # ac-canary-app-secrets may remain (keep => Delete=false)
kubectl get namespace argocd-canary                 # still exists: ArgoCD does not track the auto-created namespace
```

Expected: Deployment, Service and pods gone; the keep-annotated Secret and the namespace itself
remain. Delete them by hand, then the project and the bump branch:

```bash
kubectl delete namespace argocd-canary              # takes the leftover Secret with it
kubectl -n argocd delete appproject scratch
argocd app list                                     # empty
argocd proj list                                    # default only
git push origin --delete argocd-canary-bump
git checkout main && git branch -D argocd-canary-bump
```

Final untouched check:

```bash
scripts/argocd_canary_check.sh | tee tmp/canary-10-deleted.txt
diff <(sed -n '/^Real namespace/,/^$/p' tmp/canary-00-baseline.txt) \
     <(sed -n '/^Real namespace/,/^$/p' tmp/canary-10-deleted.txt) && echo "real namespace unchanged"
ARGOCD_PODS=4 scripts/argocd_preflight.sh           # back to the Phase 2 numbers
```

Record the history IDs, the prune and delete observations (what remained) and the before/after
numbers in the Phase 3 PR.

## 11. Abort / cleanup from any step

In this order (the Application before the project; deleting the project first can leave the
finalizer unable to run):

```bash
argocd app delete ac-canary --wait -y || true
kubectl -n argocd get application.argoproj.io ac-canary 2>/dev/null && \
  kubectl -n argocd patch application.argoproj.io ac-canary --type json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' && \
  kubectl -n argocd delete application.argoproj.io ac-canary
kubectl delete namespace argocd-canary --ignore-not-found
kubectl -n argocd delete appproject scratch --ignore-not-found
git push origin --delete argocd-canary-bump 2>/dev/null || true
scripts/argocd_canary_check.sh
```

Removing the finalizer by hand (second command) is only for a delete that hangs; it leaves anything in
`argocd-canary` to the namespace deletion on the next line. Nothing in this section can reach the
`automation-calculator` namespace: the project never allowed it as a destination, and the namespace
deletion is scoped to `argocd-canary`.

If the real namespace check ever differs from the baseline, stop and compare
`kubectl -n automation-calculator get deploy automation-calculator -o yaml` and the Ingress against
`git show origin/main:helm/automation-calculator/` before touching anything else. Terraform still
owns that release; `helm -n automation-calculator status automation-calculator` is the reference.

## 12. Done when

- Every untouched check matched the baseline: real Deployment `generation`, Ingress and Secret
  `resourceVersion`, Secret sha256 identical from section 1 through section 10.
- Sync, branch switch, rollback, prune and delete each behaved as described above, with the
  observations recorded in the PR.
- `argocd app list` is empty, `argocd proj list` shows only `default`, namespace `argocd-canary` is
  gone, branch `argocd-canary-bump` is deleted.
- `scripts/argocd_preflight.sh` exits 0 on staging.
