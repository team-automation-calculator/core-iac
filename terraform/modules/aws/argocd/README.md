# argocd

Installs ArgoCD into an EKS cluster with a single `helm_release` of the
[`argo-cd` chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd), mirroring how
`cluster-addons-layer` installs external-dns. Phase 2 of `docs/argocd-migration-plan.md`.

The module takes no cluster inputs: like the other add-on modules it relies on the `helm` provider
configured by the calling env config (`terraform/env/<env>/aws/us-west-1/cluster-addons-layer`).
Each env wires it as `module "argocd"` behind `var.argocd_enabled` (default `false`), so an env
without the flag plans zero changes.

What the release does and does not do:

- Namespace `argocd` (created by the release), chart version pinned to the Phase 0 pin in the plan.
- Dex, notifications and Redis HA off; the ApplicationSet controller scaled to zero (the chart no
  longer has `applicationSet.enabled`). Four pods: application controller, repo server, server,
  redis.
- `server.insecure=true`: the UI/API is only reachable through `kubectl port-forward`. No Ingress.
- Explicit resource requests and memory limits sized for a single `t4g.medium` (arm64; the images are multi-arch).
- No IRSA. The admin password is generated here (`random_password.argocd_admin`) and reaches the
  chart as its `bcrypt_hash` through `set_sensitive`, with a `time_static` mtime, so the chart
  never creates `argocd-initial-admin-secret`. The plaintext is the sensitive output
  `argocd_admin_password`, held in the workspace state. The hash is stable across runs because the
  resource computes it once; never use the `bcrypt()` function, which salts differently on every
  run.
- `wait = true`, `atomic = false`, `cleanup_on_fail = false`, `timeout = 900`: a failed install stays
  on the cluster for inspection instead of rolling back.

Validation and first login: `docs/argocd-phase-2-install.md`.

| Variable | Default | Purpose |
|---|---|---|
| `argocd_chart_version` | `10.11.6` | argo-cd chart version (Argo CD v3.5.6). Re-pin only in an upgrade PR together with the plan's Versions table. |
| `argocd_namespace` | `argocd` | Namespace the release creates and installs into. |
| `argocd_admin_password_rotation` | `"1"` | Rotation key. Changing it generates a new admin password and mtime, which logs every session out. |
