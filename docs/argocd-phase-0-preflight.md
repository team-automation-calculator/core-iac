# ArgoCD migration Phase 0: preflight runbook (staging)

Companion to Phase 0 of `argocd-migration-plan.md`. Everything here is read-only against the
cluster; the only possible change is a Terraform edit, made through a PR, if the capacity check
says the node is full.

## 1. Tools

```bash
brew install helm argocd          # helm for Phase 1 render diffs, argocd for Phase 2+
helm version --short              # CI pins v4.3.1 through the CircleCI orb; 4.x locally is fine
argocd version --client
```

## 2. Staging access

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # SSO login, kubeconfig, AWS_PROFILE
kubectl config current-context                                # must be the ac_app_staging cluster
```

See `aws-sso-auth.md` if the SSO profiles are not set up yet.

## 3. Capacity check

```bash
scripts/argocd_preflight.sh
```

The script prints allocatable pods per node, the current pod count, the headroom after ArgoCD's
four pods, the ALB controller replica count, and whether `helm` and `argocd` are on `PATH`. It
exits non-zero if the headroom after ArgoCD would be under 4 pods or a CLI is missing.

What the numbers mean on today's layout (one `t3.medium`, 17 allocatable pods, roughly 9 to 10
pods running):

| Headroom after ArgoCD | Action |
|---|---|
| 4 or more | Nothing to do. Proceed to Phase 1. |
| Under 4 | Free pod slots before Phase 2 installs ArgoCD. Pick one of the two options below. |

Two ways to buy headroom, in order of preference:

1. **ALB controller `replicaCount = 1`.** The chart defaults to 2 replicas, and
   `terraform/modules/aws/cluster-addons-layer/main.tf` does not override it. Two replicas on one
   node add no availability (the controller is leader-elected; the standby does nothing), so this
   frees one pod slot at no cost. Add a `set { name = "replicaCount" value = "1" }` block to
   `helm_release.aws_load_balancer_controller`. This changes all environments, which is the point:
   production has the same single-node layout.
2. **Staging `desired_size = 2`.** In `terraform/env/staging/aws/us-west-1/base-cluster-layer/main.tf`
   the node group is `desired_size = 1, max_size = 2, min_size = 1`, so a second `t3.medium` is one
   number away and doubles the pod ceiling to 34. It costs a second instance and only applies to
   staging; production would need its own change (and raising `max_size` there, which is 1 by
   default in `terraform/modules/aws/base-cluster-layer/variables.tf`). Prefer this when the
   shortfall is more than one slot or when the app itself is expected to grow.

Either change goes through a normal PR. Staging auto-applies; re-run `scripts/argocd_preflight.sh`
afterwards and record the new numbers in the PR.

## 4. Pin the chart versions

```bash
python3 -I scripts/argo_helm_chart_versions.py --fetch
```

This downloads `https://argoproj.github.io/argo-helm/index.yaml` into `tmp/argo-helm-index/`
(gitignored) and prints the highest stable `argo-cd` and `argocd-apps` chart versions with their
`appVersion`. Record them under Phase 0 "Versions" in `argocd-migration-plan.md` with the date;
Phases 2 and 5 use those pins verbatim. Re-run and re-pin only deliberately, as part of an upgrade PR.

The same answer with `yq`, if preferred:

```bash
yq '.entries.argo-cd[0] | [.version, .appVersion] | join(" ")' tmp/argo-helm-index/index.yaml
yq '.entries.argocd-apps[0].version' tmp/argo-helm-index/index.yaml
```

(The index lists newest first, but the Python script does not rely on that ordering and skips
prereleases and deprecated entries.)

## 5. Done when

- `scripts/argocd_preflight.sh` exits 0 on the staging context.
- Chart versions are recorded in the plan with a date.
- `helm` and `argocd` are installed locally.
