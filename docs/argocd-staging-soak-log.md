# ArgoCD staging soak log

Phase 7 of `argocd-migration-plan.md`: every bump and rollback cycle that ArgoCD synced on
staging, recorded with `scripts/argocd_soak_log.py add` after `scripts/argocd_staging_verify.sh`
passed (runbook: `argocd-phase-7-staging-soak.md`). The Gate section is rewritten by
`scripts/argocd_soak_log.py status`; it must read **PASS** before Phase 8 (production) starts.

Columns: merge date; `bump` or `rollback`; the `image.tag` the cycle deployed; the merged PR;
the `ID` of the `argocd app history automation-calculator` entry that deployed it; merge to
sync-finished time; whether anyone had to do anything beyond "merge and wait" (`yes` restarts
the gate's counts); notes (TFC staging plan result, anything odd).

## Cycles

| Date | Kind | Tag | PR | ArgoCD history ID | Time to sync | Manual intervention | Notes |
|---|---|---|---|---|---|---|---|

## Gate

<!-- Managed by scripts/argocd_soak_log.py; do not edit by hand. -->

Not yet evaluated: run `scripts/argocd_soak_log.py status`.
