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
| 2026-11-24 | bump | 0.9.6-998 | #469 | 1 | 1m28s | no | Merged 23:54:50Z, synced 23:56:18Z by automated, new pod Ready by 23:56:59Z. Staging TFC plan: no changes. Verify OK. |
| 2026-11-25 | rollback | 0.9.6-996 | #471 | 2 | 3s | no | Rollback test: revert of #469. Merged 00:08:31Z, synced 00:08:34Z by automated, Healthy by 00:08:51Z. Staging TFC plan: no changes. Verify OK. |
| 2026-11-25 | bump | 0.9.6-1014 | #476 | 3 | 1m27s | no | Merged 00:21:16Z, synced 00:22:43Z by automated, new pod Ready by 00:23:23Z. Staging TFC plan: no changes. Verify OK. |
| 2026-11-25 | bump | 0.9.6-1021 | #478 | 5 | 1m15s | no | Merged 01:31:47Z, synced 01:33:02Z by automated, both new pods Ready by 01:33:50Z, old pods gone by 01:34:38Z. First bump with 2 replicas and the staging-only bump PR. History ID 4 was the #474 chart change (2 replicas, PDB), also synced by automated. Staging TFC plan: no changes. Verify OK. |

## Gate

<!-- Managed by scripts/argocd_soak_log.py; do not edit by hand. -->

**FAIL** as of 2026-11-25: Phase 8 may not start yet.

- PASS: 3 bump cycle(s) without manual intervention (need 3)
- FAIL: 1 day(s) since the first clean cycle on 2026-11-24 (need 3)
- note: 1 rollback cycle(s) recorded (the plan's revert test)
