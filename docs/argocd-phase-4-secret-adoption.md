# ArgoCD migration Phase 4: Terraform adopts the app namespace and Secret (all envs)

Companion to Phase 4 of `argocd-migration-plan.md`. Terraform takes ownership of the
`automation-calculator` namespace and the `automation-calculator-app-secrets` Secret, both of which
Helm created and has managed until now. Nothing is recreated: each env's TFC workspace adopts the
live objects through `import` blocks, and the only Helm change is that the chart stops rendering
the Secret. Pods are not restarted, the Secret's data does not change, the Ingress is not touched.

## 1. What the PR changes

- `terraform/modules/aws/main_rails_app/main.tf`
  - `kubernetes_namespace_v1.automation_calculator`: name only, with
    `ignore_changes` on labels and annotations (the namespace's metadata is not Terraform's) and
    `prevent_destroy` (deleting the namespace deletes the Ingress and therefore the ALB).
  - `kubernetes_secret_v1.app_secrets`: `automation-calculator-app-secrets`, `type = "Opaque"`, the
    six keys the chart's `templates/secret.yaml` rendered (`databaseUrl`, `githubOAuthAppId`,
    `githubOAuthAppSecret`, `googleOAuthAppId`, `googleOAuthAppSecret`, `secretKeyBase`) built from
    the exact expressions the six `set_sensitive` blocks used. Its labels and annotations mirror
    what Helm left on the live object (chart labels, `app.kubernetes.io/managed-by: Helm`,
    `helm.sh/resource-policy: keep`, `meta.helm.sh/release-name` and `-namespace`) so the import
    plans clean. The two `meta.helm.sh` annotations also let a revert re-adopt the Secret into the
    release (section 7).
  - `helm_release.automation-calculator`: the six `set_sensitive` blocks are gone; it `depends_on`
    the namespace and the Secret so a fresh environment creates them first. `create_namespace`
    stays `true` (a no-op now) so this phase's release diff is only the removed blocks.
  - `versions.tf`: `kubernetes ~> 2.16`; the lock file gains the kubernetes provider block. The
    env configs already declare the `kubernetes` provider (`provider.tf`) and pass it implicitly.
- `terraform/env/{staging,production}/aws/us-west-1/cluster-addons-layer/imports_argocd_phase4.tf`:
  the two `import` blocks. **Not in development**: its cluster is unprovisioned, so there is nothing
  to adopt and an `import` of a missing object fails the plan; when development is next provisioned
  Terraform creates both resources itself.
- `helm/automation-calculator/values-{development,staging,production}.yaml`: `secrets.create:
  false`. `values.yaml` keeps the default `true` so standalone renders (the Phase 3 canary passes
  `secrets.create=true` as a parameter and its own Secret name) are self-contained.
- `CLAUDE.md`: secrets no longer come through `set_sensitive`.

The Secret survives the Helm upgrade that drops it from the manifest because of
`helm.sh/resource-policy: keep` on the **live** object (section 2 checks it). There is no window
without a Secret: Terraform owns it from the moment the plan imports it.

## 2. Before merging: pre-checks per environment

Run for staging first, then production. Everything here is read-only.

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # or production
kubectl config current-context                                # must be the right cluster
mkdir -p tmp
scripts/argocd_canary_check.sh | tee tmp/phase4-<env>-before.txt
```

Keep the file: the "Real namespace" block (Deployment generation, Ingress and Secret
resourceVersion, Secret sha256 and key list) is the baseline for section 5. The key list must be
exactly the six keys in section 1: `databaseUrl githubOAuthAppId githubOAuthAppSecret
googleOAuthAppId googleOAuthAppSecret secretKeyBase`. Any other key, or a missing one, means the
live Secret and the module disagree and the import would plan a `data` change. Stop.

The `keep` policy must be on the live Secret (Phase 1's belt-and-braces step), or Helm deletes the
Secret during the upgrade:

```bash
kubectl -n automation-calculator get secret automation-calculator-app-secrets \
  -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}'; echo        # keep
```

If it prints anything else, annotate first and re-check:

```bash
kubectl -n automation-calculator annotate secret automation-calculator-app-secrets helm.sh/resource-policy=keep
```

Compare the live metadata with the module so the plan is predictable:

```bash
kubectl -n automation-calculator get secret automation-calculator-app-secrets \
  -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
kubectl get namespace automation-calculator \
  -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
```

Expected on the Secret: labels `app.kubernetes.io/instance=automation-calculator`,
`app.kubernetes.io/managed-by=Helm`, `app.kubernetes.io/name=automation-calculator`,
`app.kubernetes.io/version=1.0.0`, `helm.sh/chart=automation-calculator-0.1.0`; annotations
`helm.sh/resource-policy=keep`, `meta.helm.sh/release-name=automation-calculator`,
`meta.helm.sh/release-namespace=automation-calculator`. Expected on the namespace: only
`kubernetes.io/metadata.name` (ignored by the provider) and whatever else is there (ignored by
`ignore_changes`). A difference on the Secret is not a blocker, it just shows up as an in-place
metadata update in the plan (section 3); note it so the plan reads as expected.

Finally, the TFC variables `github_oauth_app_id`, `github_oauth_app_secret`, `google_oauth_app_id`
and `google_oauth_app_secret` must be what the last `helm upgrade` injected. If any of them changed
in TFC since the last cluster-addons apply, the import will plan a `data` change on the Secret
(sensitive, so the plan does not say which key). Decide before merging whether that change is
wanted; it takes effect on the next pod restart, not on apply.

## 3. Expected plan per workspace

Read the speculative plan TFC attaches to the PR, or run `terraform plan` from the env directory
with `TFE_TOKEN` set (it runs remotely and streams the output).

| Workspace | Expected plan |
|---|---|
| `ac_app_staging_cluster_addons_layer` | **2 to import**: `module.main_rails_app.kubernetes_namespace_v1.automation_calculator`, `module.main_rails_app.kubernetes_secret_v1.app_secrets`. **1 to change**: `module.main_rails_app.helm_release.automation-calculator` in place, only the `set_sensitive` blocks removed (`values` unchanged). 0 to add, 0 to destroy. Auto-applies on merge. |
| `ac_app_production_cluster_addons_layer` | Same. Needs a confirm. |
| `ac_app_development_cluster_addons_layer` | No cluster: the plan fails at `data.aws_eks_cluster` as it did before this PR, or, if it ever runs, 2 to add. No imports. |

Acceptable in addition: an in-place update of the imported Secret that only touches
`metadata.labels` / `metadata.annotations` (section 2 told you which), and an in-place update of
the namespace limited to metadata (it should not appear at all thanks to `ignore_changes`).

**Stop and do not apply** if the plan shows any of:

- `~ data = (sensitive value)` on the Secret (the module and the live Secret disagree on a value;
  section 2, last paragraph).
- Any replacement (`-/+`) or destroy of anything (`prevent_destroy` on the namespace makes such a
  plan fail outright).
- A change to `module.cluster_addons`, `module.argocd`, the Deployment-affecting values of the
  release, or `terraform.tfvars`: not this PR.
- "Cannot import non-existent remote object": the kubeconfig the run used does not see the
  namespace or Secret; the workspace credentials or the cluster are wrong.

## 4. Apply order and cautions

1. **Staging** auto-applies on merge. Watch the run; then do section 5 on staging.
2. **Production** plans on the same merge. The import reads the live Secret with the plan-time EKS
   token (15-minute STS), so **confirm promptly**. If the plan is older than a few minutes or the
   confirm fails with "the server has asked for the client to provide credentials", discard it and
   queue a fresh plan from the TFC UI, then confirm immediately. A failed apply after a successful
   plan has imported nothing (imports are recorded on apply), so the next plan simply imports
   again.
3. Both applies run `helm upgrade --atomic`. The Secret leaves the release manifest; Helm logs it as
   kept, not deleted. The Deployment's pod template is unchanged, so there is no rollout.

Do not merge anything else that touches the cluster-addons workspaces between the staging apply and
the production confirm.

## 5. Post-apply validation per environment

```bash
scripts/argocd_canary_check.sh | tee tmp/phase4-<env>-after.txt
diff <(sed -n '/^Real namespace/,/^$/p' tmp/phase4-<env>-before.txt) \
     <(sed -n '/^Real namespace/,/^$/p' tmp/phase4-<env>-after.txt)
```

Expected: the Secret `data sha256` and `keys` lines identical, the Deployment `generation` identical
(`resourceVersion` may move if a status update landed). The Secret `resourceVersion` changes only if
the plan patched its metadata.

```bash
kubectl -n automation-calculator get pods                     # same pod names, AGE and RESTARTS as before
kubectl -n automation-calculator get secret automation-calculator-app-secrets \
  -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}'; echo        # keep
helm -n automation-calculator status automation-calculator    # STATUS: deployed, REVISION +1
helm -n automation-calculator get manifest automation-calculator | grep -c 'kind: Secret'   # 0
curl -fsS https://<host>/health
```

In TFC (or from the env directory with `TFE_TOKEN`): `terraform state list | grep kubernetes_`
shows both resources, and a fresh plan shows **0 changes**. The import blocks are idempotent, so
they can stay until the cleanup PR below.

## 6. Cleanup after both environments

Open a small PR that deletes both `imports_argocd_phase4.tf` files; it plans 0 changes everywhere.
Do this promptly rather than waiting for Phase 9: an `import` block whose object is ever missing
fails the plan.

## 7. Rollback

Nothing on the cluster changed except the release manifest, so most problems are fixed forward (the
Secret's data is a Terraform expression now; change it there). If the phase must be reverted:

1. **Never merge a revert that removes the two resources from the module while they are still in
   state.** Terraform would plan to destroy the Secret and, `prevent_destroy` notwithstanding (the
   guard goes away with the block), the namespace, and with it the Ingress and the ALB.
2. In each workspace that applied this phase, forget the objects first:

   ```bash
   cd terraform/env/<env>/aws/us-west-1/cluster-addons-layer
   terraform init
   terraform state rm module.main_rails_app.kubernetes_secret_v1.app_secrets
   terraform state rm module.main_rails_app.kubernetes_namespace_v1.automation_calculator
   ```

3. Then merge the revert PR (set_sensitive back, `secrets.create` back to default, the import
   files gone). The `helm upgrade` renders the Secret again and adopts the existing object: Helm
   accepts it because the live Secret still carries `meta.helm.sh/release-name` /
   `release-namespace` and `app.kubernetes.io/managed-by: Helm`, which is why the module kept them.
   The plan for that merge is 1 to change (the release); anything else means step 2 was skipped.

If a run was confirmed and failed mid-apply (expired token), nothing needs rolling back: re-plan
and confirm promptly (section 4).

## 8. Done when

- Staging and production each: imports applied, `helm status` deployed, Secret sha256 and
  Deployment generation unchanged, no pod restarts, health endpoint 200, fresh plan 0 changes.
- Cleanup PR (section 6) merged.
- Development untouched (no cluster).
