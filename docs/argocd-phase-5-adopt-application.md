# ArgoCD migration Phase 5: adopt the real Application in place (staging)

Companion to Phase 5 of `argocd-migration-plan.md`. Terraform creates the real `AppProject` and
`Application` for the app on staging; the Application then **adopts** the Service, Deployment and
Ingress that Terraform's Helm release already manages, without recreating or rolling anything.
After this phase two controllers know about the app, which is why the Application stays on
**manual sync** until Phase 6 makes Terraform forget the release.

The one rule for the whole phase: **nothing may touch the Ingress.** Deleting the Ingress deletes
the ALB, and external-dns can leave an orphaned TXT record behind. Every step below is built
around that (no finalizer, no prune, no `helm uninstall`, `--cascade=false` on any delete).

## 1. What the PR changes

- `terraform/modules/aws/argocd/`: a second release, `helm_release.argocd_apps`, of the
  `argocd-apps` chart (version pinned under Phase 0 "Versions" in the plan; CR manifests only, no
  controller), namespace `argocd`, `depends_on = [helm_release.argocd]`, `wait = true`,
  `atomic = false`, `cleanup_on_fail = false`, behind `manage_application` (default `true`). Its
  values render:
  - `AppProject` `automation-calculator`: source repos limited to this repository, destinations
    limited to namespace `automation-calculator` on the local cluster, cluster-scoped kinds limited
    to the `automation-calculator` `Namespace` (the `CreateNamespace=true` PreSync task is checked
    against the project like any other resource; Phase 3 hit this).
  - `Application` `automation-calculator`: `repoURL` this repository, `targetRevision: main`,
    `path: helm/automation-calculator`, `helm.releaseName: automation-calculator`,
    `valueFiles: [values.yaml, values-staging.yaml]`, one parameter
    `ingress.certificateArn=<ACM ARN>` (from the new `main_rails_app` output
    `automation_calculator_app_certificate_arn`), destination `automation-calculator`,
    `syncOptions: [CreateNamespace=true]`, **no** `resources-finalizer.argocd.argoproj.io`, **no**
    `automated` sync policy.
  - The sync policy is driven by `application_automated_sync` / `application_prune` /
    `application_self_heal` (all default `false`) so Phase 6 flips staging without changing the
    module logic.
- `terraform/modules/aws/main_rails_app/outputs.tf`: the certificate ARN output.
- Each env's `cluster-addons-layer/main.tf` passes `app_certificate_arn`, `app_repo_url`,
  `environment_name` and `manage_application` (new env variables `app_repo_url`, defaulting to
  this repository, and `argocd_manage_application`, defaulting to `true`). The module is still
  behind `argocd_enabled`, which only staging sets.

The release name inside the Application must be `automation-calculator`: it feeds
`app.kubernetes.io/instance` in the Deployment's immutable `spec.selector.matchLabels`
(`helm/automation-calculator/templates/_helpers.tpl`). Any other name makes the Deployment sync
fail and rewrites the Service selector to match zero pods. It is a local in the module, not a
variable, for that reason.

## 2. Expected TFC plans

| Workspace | Expected plan |
|---|---|
| `ac_app_staging_cluster_addons_layer` | **1 to add**: `module.argocd[0].helm_release.argocd_apps[0]`. 0 to change, 0 to destroy. Auto-applies on merge. |
| `ac_app_production_cluster_addons_layer` | 0 changes (`argocd_enabled` is false). |
| `ac_app_development_cluster_addons_layer` | No cluster: the plan fails at `data.aws_eks_cluster` as it did before this PR; if it ever runs, 0 changes. |

The `main_rails_app` output is module-internal and does not appear in a plan. **Stop and do not
apply** if the staging plan shows anything on `module.main_rails_app` (in particular its
`helm_release`), on `module.argocd[0].helm_release.argocd`, or on `module.cluster_addons`: none of
that is this PR.

The apply runs `helm install argocd-apps`. The two CRs are accepted by the API server within
seconds; ArgoCD's controller then reconciles the Application and reports it `OutOfSync` (the
tracking annotation is missing from the live objects) and `Healthy`. Nothing is deployed: the
Application has no automated sync policy.

## 3. Before the apply: baseline the real namespace

Everything here is read-only. Run it before merging and keep the output.

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # SSO login, kubeconfig, AWS_PROFILE
kubectl config current-context                                # must be the ac_app_staging cluster
mkdir -p tmp
CANARY_APP=automation-calculator scripts/argocd_canary_check.sh | tee tmp/phase5-00-baseline.txt
kubectl -n automation-calculator get ingress automation-calculator -o yaml > tmp/phase5-00-ingress.yaml
kubectl -n automation-calculator get deploy automation-calculator -o yaml > tmp/phase5-00-deploy.yaml
kubectl -n automation-calculator get pods -o wide | tee tmp/phase5-00-pods.txt
```

`CANARY_APP=automation-calculator` points the Phase 3 script's last block at the real Application
(it prints "not found" until the apply). The "Real namespace" block is the baseline: the
Deployment `generation`, the Secret `resourceVersion` and `data sha256` must never change in this
phase. The Deployment and Ingress `resourceVersion`s **will** move once, at the first sync, when
ArgoCD writes its annotations; the `-o yaml` captures are what you diff against to prove that is
all that moved.

Also note the ALB hostname; it must be the same at the end:

```bash
kubectl -n automation-calculator get ingress automation-calculator -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

## 4. After the apply: inspect the Application, then its diff

Port-forward and log in as in `argocd-phase-2-install.md`. In one terminal:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

In another:

```bash
argocd login localhost:8080 --username admin --plaintext
argocd proj get automation-calculator       # sources: this repo; destinations: automation-calculator only
argocd app get automation-calculator        # Project automation-calculator, Sync OutOfSync, Health Healthy
kubectl -n argocd get application.argoproj.io automation-calculator -o jsonpath='{.metadata.finalizers}'; echo   # empty
```

The finalizer check is the important one: it must print nothing. If it prints
`resources-finalizer.argocd.argoproj.io`, stop; the module rendered something it should not have,
and a later delete would cascade to the Ingress.

Confirm the manifest set, then the diff:

```bash
argocd app manifests automation-calculator | yq -N '[.kind, .metadata.name] | join(" ")'
argocd app diff automation-calculator | tee tmp/phase5-01-diff.txt
```

Expected manifests: `Service automation-calculator`, `Deployment automation-calculator`,
`Ingress automation-calculator`. No Secret (`values-staging.yaml` sets `secrets.create: false`),
no object with any other name, no Namespace (the `CreateNamespace` task is not a manifest).

Expected diff, and nothing else: for each of the three objects, one added annotation,

```
+    argocd.argoproj.io/tracking-id: automation-calculator:<group>/<Kind>:automation-calculator/automation-calculator
```

(`argocd app diff` exits 1 whenever there is a diff; that is expected here.) ArgoCD compares the
desired manifest against the live object with a merge-patch semantics in which live-only fields are
ignored, so Helm's own `meta.helm.sh/release-*` annotations, the ALB controller's finalizer and
status, Kubernetes defaults and `deployment.kubernetes.io/revision` do not show. Only what ArgoCD
would **set** shows, and before the first sync that is the tracking annotation.

**Do not sync** if the diff shows anything under `spec`. Specifically:

- Any line under the Deployment's `spec.template` (image, env, probes, resources, labels): the
  chart on `main` renders differently from what Terraform last applied. Usually a values file
  changed on `main` after the last staging apply (a bump merged but the TFC run did not apply yet),
  or the PR branch's chart differs from `main`. Wait for the two to converge, re-check, then sync.
- Any line on `spec.selector` of the Deployment or Service: the release name is wrong. Nothing
  short of recreating the Deployment fixes that; the module must be corrected and the Application
  replaced (section 7) before anything else.
- Any line on the Ingress annotations (`alb.ingress.kubernetes.io/*`): the ALB would be modified
  or replaced. `load-balancer-name`, `scheme` and `target-type` especially.

The UI shows the same thing: Application tile, "App Diff", "Compact diff" on. Three resources,
each with the one annotation line.

## 5. First sync

```bash
argocd app sync automation-calculator --timeout 300
argocd app get automation-calculator        # Sync Synced, Health Healthy
argocd app history automation-calculator    # ID 0, revision = current main SHA
```

The sync `kubectl apply`s the three manifests. Because no field under `spec` differed, the only
writes are the tracking annotation and `kubectl.kubernetes.io/last-applied-configuration` on each
object. The PreSync `CreateNamespace` task finds the namespace (Terraform's) and does nothing;
the AppProject's `clusterResourceWhitelist` is what lets it run at all.

If the sync is refused with `resource :Namespace is not permitted in project
automation-calculator`, the AppProject was not rendered with the whitelist; check
`argocd proj get automation-calculator` against section 1 and the module before retrying.

## 6. Post-sync checks

```bash
CANARY_APP=automation-calculator scripts/argocd_canary_check.sh | tee tmp/phase5-02-synced.txt
diff tmp/phase5-00-baseline.txt tmp/phase5-02-synced.txt
```

Expected in that diff: the Deployment and Ingress `resourceVersion` lines (the annotation writes),
the `Time:` line and the Application block (Synced / Healthy / Succeeded). The Deployment
`generation`, the Secret `resourceVersion`, `data sha256` and `keys` must be identical.

```bash
kubectl -n automation-calculator get deploy automation-calculator -o yaml > tmp/phase5-02-deploy.yaml
kubectl -n automation-calculator get ingress automation-calculator -o yaml > tmp/phase5-02-ingress.yaml
diff tmp/phase5-00-deploy.yaml tmp/phase5-02-deploy.yaml
diff tmp/phase5-00-ingress.yaml tmp/phase5-02-ingress.yaml
```

Expected in both diffs: `argocd.argoproj.io/tracking-id` and
`kubectl.kubernetes.io/last-applied-configuration` added under `metadata.annotations`,
`resourceVersion` changed, a new `managedFields` entry for `argocd-controller`. Nothing under
`spec`, nothing under `status`.

```bash
kubectl -n automation-calculator get pods -o wide                 # same pod names, AGE and RESTARTS as tmp/phase5-00-pods.txt
kubectl -n automation-calculator get ingress automation-calculator -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo   # same ALB
curl -fsS https://staging.automation-calculations.io/health
helm -n automation-calculator status automation-calculator       # STATUS: deployed, same REVISION as before
scripts/argocd_preflight.sh                                      # pod headroom unchanged: the Application adds no pods
```

Finally, Terraform must still agree with the cluster. The Helm provider never reads live objects,
so the annotations ArgoCD added are invisible to it: a fresh speculative plan on
`ac_app_staging_cluster_addons_layer` shows **0 changes**. If it does not, something other than
this phase changed; understand it before moving on.

## 7. Rollback

Terraform's Helm release still owns everything in `automation-calculator`; the Application is only
a second observer. Rolling it back therefore never touches the app, provided the delete does not
cascade.

**Preferred, Terraform-native:** set `argocd_manage_application = false` in staging's
`terraform.tfvars` through a PR. The plan is 1 to destroy
(`module.argocd[0].helm_release.argocd_apps[0]`); the apply `helm uninstall`s the two CRs. The
Application has no finalizer, so Kubernetes deletes it without ArgoCD's cascade; the Service,
Deployment and Ingress keep their tracking annotations (harmless; ArgoCD re-adopts them when the
Application comes back). `argocd_enabled = false` is the bigger hammer from Phase 2 and is equally
safe for the same reason.

**By hand, if ArgoCD must be stopped from looking at the app right now:**

```bash
argocd app delete automation-calculator --cascade=false -y
```

**Never omit `--cascade=false`.** `argocd app delete` with the default cascade first *adds* the
resources-finalizer to the Application and then deletes it, which deletes the Ingress and the ALB.
The same goes for the UI's delete dialog: its "Foreground" / "Background" options cascade; only
"Non-cascading" is safe. `kubectl -n argocd delete application automation-calculator` is also
safe (it only deletes the object you name). After a manual delete the Terraform state still holds
the release while the cluster does not have the Application: either follow up with the tfvars PR
above (the plan will then show a destroy of a release whose CRs are already gone; that is fine), or
bring it back with `terraform apply -replace='module.argocd[0].helm_release.argocd_apps[0]'`
run from the TFC UI as a plan with that replacement.

What **not** to do, in any rollback: `helm uninstall automation-calculator` (deletes the Ingress),
`argocd app sync --prune` (nothing to prune today, but the habit is wrong until Phase 6),
`kubectl delete namespace automation-calculator` (`prevent_destroy` exists for a reason).

## 8. Manual sync, and why it stays that way

Until Phase 6 runs `terraform state rm` on the release, both Terraform and ArgoCD read
`helm/automation-calculator/values-staging.yaml` and both can write the Deployment. They agree as
long as `main` and the last staging TFC apply match, but two controllers must never reconcile the
same object on their own:

- The Application has no `automated` block. `argocd app sync` is the only way it writes, and only
  after you have looked at `argocd app diff`.
- A bump PR merged in this window is applied by Terraform (the TFC run) as today. ArgoCD then
  shows `OutOfSync` on the tracking annotation of the new pod template until someone syncs it,
  which is harmless and expected; sync it after the TFC apply so the two agree again, or leave it.
- Do not set `application_automated_sync = true` anywhere until that env's Phase 6 `state rm` is
  done.

## 9. Done when

- Staging TFC run applied with exactly 1 resource added; production planned 0.
- `argocd app get automation-calculator`: project `automation-calculator`, Synced, Healthy; no
  finalizer on the Application; `argocd app history` shows ID 0 at the `main` SHA.
- The section 4 diff showed only the tracking annotation; the section 6 diffs show only
  annotations and `managedFields`; Deployment `generation`, Secret `resourceVersion` and sha256
  unchanged; same pods, same ALB hostname; health endpoint 200; `helm status` deployed at the
  same revision.
- A fresh staging plan shows 0 changes.
- The Application is on manual sync and this runbook's section 8 is understood by whoever merges
  the next bump.
