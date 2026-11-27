# Rollout timings

Verified: 2026-11-27

Measured outages and durations, for the expected-vs-actual line of a PR body or a quiet-window
notice. Outages are measured on `/health` polled every 3 to 5 seconds (`./go health-poll`), unless a
row says otherwise. When a new measurement differs, add a row instead of overwriting the old one,
and say what changed (replica count, node type, instance class).

## App image

| Change | Where, PR, date | Measured |
|---|---|---|
| Image bump, ArgoCD automated sync | staging, #469 / #476 / #478, 2026-11-24/25 | Synced 1 min 15 s to 1 min 28 s after merge (polling interval 3 min), no non-200 |
| Rollback by revert PR, ArgoCD automated sync | staging, #471, 2026-11-25 | Synced 3 s after merge |
| Image bump by moving the pin (`argocd_app_target_revision`), automated sync, 2 replicas | production, #517, 2026-11-27 | Merge to TFC apply done 2 min 33 s, rollout finished about 1 min later, `/health` flipped 4 min 45 s after merge, 0 non-200 in 111 polls (2 s), no alarm metric non-zero |
| Image bump through Terraform, 2 replicas (before Phase 8) | production, #481, 2026-11-25 | About 5 min merge to new `short_commit_hash`, 0 non-200 in 81 polls |
| Image bump through Terraform, 1 replica (before ArgoCD) | production, #419, 2026-11-07 | 547 s merge to new hash (included a confirm), 0 non-200 |

Since #511 a production image bump is a production PR that moves the pin (`docs/promotion.md`); the
#517 row is the first. `rollout status` reported done about 1 min before `/health` flipped: the
old pod kept answering through its `preStop` sleep while the ALB health-checked the new targets.
Wait until the old pods are gone before reading the hash.

## Nodes and the control plane

| Change | Where, PR, date | Measured |
|---|---|---|
| Node group replaced (arm64 move), 1 replica | staging, #409, 2026-11-05 | One 85 s outage (timeouts, then a 502); 9 min merge to done |
| Node group replaced (arm64 move), 1 replica | production, #410, 2026-11-07 | One 88 s outage; about 8 min apply start to old node gone |
| AMI release bump, node group in place | staging, #408, 2026-11-04 | New node about 3 min after apply start, every pod rescheduled once, `/health` stayed 200 |
| EKS minor upgrade 1.36 to 1.37 | staging, #360, 2026-11-04 | Control plane about 10 min, node group about 13 min, 2 surge nodes, 2 outages of about 1 min 55 s, about 23 min apply start to done |
| EKS minor upgrade 1.36 to 1.37 | production, #361, 2026-11-05 | Control plane about 7 min, node group about 14 min, 3 surge nodes, 1 outage of 1.5 to 2 min, about 23 min apply start to done |

With one replica the outage is eviction to Ready plus ALB registration. In an EKS minor upgrade the
managed node group surges 2 or 3 nodes for a desired size of 1, and the app is moved a second time
only if EKS later drains the surge node it landed on, so expect one or two outages of about 2 minutes
in a 15 minute window that starts 8 to 10 minutes after the apply. All of these rows predate the
2 replicas, PodDisruptionBudget and `preStop` sleep (#474, #482; "Surviving a node drain" in
`AGENTS.md`); a node roll with them has not been timed yet.

## RDS (db.t4g.micro)

| Change | Where, PR, date | Measured |
|---|---|---|
| `backup_retention_period` 0 to 7 | staging, #414, 2026-11-04 | 503 for 10 to 11 s about 1 min after the instance went `modifying`; then 5 to 7 more min `modifying` (first automated snapshot) with `/health` 200; TFC run 12 to 14 min |
| `backup_retention_period` 0 to 7 | production, #415, 2026-11-07 | Same shape as staging |
| PostgreSQL major upgrade 16.13 to 18.6 | staging, #363, 2026-11-26 | 4 min 35 s of non-200 |
| PostgreSQL major upgrade 16.13 to 18.6 | production, #364, 2026-11-26 | 4 min 44 s of non-200 |

The retention outage only happens on a 0 to non-zero (or back) transition; a change between two
non-zero values is documented by AWS as downtime-free. In the major upgrade the app goes 503 then
502 about 20 s after `upgrading`; most of the outage is the pre-upgrade backup (about 3.5 min) and
the engine upgrade itself about 20 s. App pods restart about 6 times and recover about 30 s after the
database accepts connections. PostgreSQL 18 kept the planner statistics across the upgrade.

## Add-ons

| Change | Where, PR, date | Measured |
|---|---|---|
| ArgoCD Helm release installed | staging, #380, 2026-11-19 | About 5 min apply, app untouched |
| ArgoCD Helm release installed | production, #386, 2026-11-25 | About 5 min merge to applied (4 added), app untouched |
