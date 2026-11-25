# RDS PostgreSQL instance sizing: cost and reliability investigation

Status: **proposal** (draft PR). Nothing below is implemented. This document records what the
app's RDS PostgreSQL instances cost today, what they actually use, and what each sizing, storage,
availability and reservation option would cost or save, so the decisions can be made from
numbers rather than from the instance-class list.

Prices were checked on 2026-11-05 against the AWS public price list for US West (N. California,
`us-west-1`) (bulk CSV version `20261029070635`), the RDS reserved-instance offerings returned by
`aws rds describe-reserved-db-instances-offerings` for this account, and the RDS User Guide
(sources at the end). Monthly figures use **730 hours** and on-demand rates, rounded to whole
dollars; hourly rates keep three decimals because they are tiny. Utilization numbers are the real
CloudWatch metrics for the two live instances over the 14 days to 2026-11-05, pulled with
`scripts/rds_utilization_summary.py`. Anything marked **verify** could not be confirmed from a
public page, the API or this repo and should be checked before acting on it.

## Summary and recommendation

- **There are two instances, not three.** The development environment's cluster and database are
  intentionally unprovisioned (`docs/dependency-upgrade-plan-2026-q4.md`), so the estate is one
  single-AZ `db.t4g.micro` for staging and one for production, both 10 GiB gp2, both
  PostgreSQL 16.13, both running 24x7. **Total RDS spend today: $33 per month, $401 per year**
  ($17 per environment: $15 instance + $1 storage + $0 backups). Any "stop dev at night" saving is
  $0 because there is no dev instance to stop.
- **`db.t4g.micro` is the floor for RDS PostgreSQL and it has headroom, with one caveat.** Over 14
  days CPU averaged 2.8% (production) and 3.6% (staging) against a 10% baseline, the CPU credit
  balance sat pinned at its 288 maximum, no surplus credits were charged, connections peaked at 3,
  and storage burst balance never dropped below 99%. The caveat is memory: of the 1 GiB,
  freeable memory bottomed at 146 MiB (production) and 118 MiB (staging) with about 15 MiB of
  swap in use. The instance is not CPU- or I/O-bound; if it ever needs a bump it will be for RAM,
  and the bump is `db.t4g.small` at **+$16 per month per instance**. The earlier figure in
  `plans/rate-limit-shared-cache-store.md` is confirmed.
- **Recommended change 1: gp2 to gp3, which forces 10 GiB to 20 GiB. Cost +$3 per month for both
  environments (+$33 per year).** In us-west-1 gp2 and gp3 are the same $0.138 per GB-month, so
  the storage type change itself is free, but the RDS API only allows gp3 at 20 GiB and above
  (confirmed with `describe-valid-db-instance-modifications`), so the real cost is the extra
  10 GiB. For that the volume goes from a 100 IOPS baseline with a burst bucket to a flat
  3,000 IOPS / 125 MiB/s with no bucket to run out, storage headroom doubles, and the free backup
  allowance (100% of allocated storage) doubles. No downtime: the RDS settings table lists
  downtime only for conversions to or from magnetic storage.
- **Recommended change 2: buy reserved instances. Saves $122 per year (1-year All Upfront, $246)
  or $192 per year (3-year All Upfront, $528) on the two micros.** RDS has no Savings Plans; RIs
  are the only commitment discount. RDS RIs are size-flexible within an instance family and
  engine in a region, so micro RIs bought now still pay out if production later moves to
  `db.t4g.small` or Multi-AZ (they then cover half of the larger footprint, pro rata). They are
  bound to the engine (PostgreSQL, any version, so the 16 to 18 upgrade is fine) and to the
  `db.t4g` family. This is a one-time manual purchase, not Terraform.
- **Not recommended now, but priced so the trade is visible:** Multi-AZ for production is
  **+$17 per month (+$209 per year)**, the only option here that improves availability (automatic
  failover in 1 to 2 minutes, class changes and OS patches done on the standby first).
  `db.t4g.small` for production is **+$16 per month (+$193 per year)** and buys 2 GiB of RAM and a
  20% CPU baseline; adopt it when the memory numbers say so, not pre-emptively.
- **Dismissed:** stopping an instance on a schedule (no dev instance; staging is used by deploys,
  smoke tests and Terraform Cloud runs at arbitrary times, and RDS auto-restarts after 7 days, so
  the saving would be at most $11 per month for a scheduler and a broken pipeline);
  consolidating staging and production onto one instance (separate blast radius is the point);
  Aurora Serverless v2 with auto-pause (its 0.5 ACU running floor is $58 per month, nearly four
  times a micro, and the always-on app pod and health checks would keep it awake; it only wins
  if the database is paused more than 72% of the time).
- **Net effect of the recommendations:** from **$33 per month ($401 per year)** to **$26 per month
  ($312 per year)** with gp3 and 1-year All Upfront RIs, or **$20 per month ($242 per year)** with
  gp3 and 3-year All Upfront RIs. Reliability goes up (guaranteed storage IOPS, double the
  storage and backup headroom) and nothing goes down.
- **Order of work:** finish the backup retention rollout (#414 applied on staging, #415 pending
  for production) and the PostgreSQL 18.6 upgrade (#363 staging, #364 production) first, then
  the gp3 change as its own small PR per environment (staging then production), then buy the
  RIs. The RI purchase does not depend on anything else and could be done today; the only reason
  to wait is if a decision to leave RDS PostgreSQL or the `db.t4g` family is plausible within the
  term.

## Current state

### Instances

Both instances are created by `terraform/modules/aws/main_rails_app/main.tf`
(`aws_db_instance.automation_calculator_app`): `allocated_storage = 10`,
`max_allocated_storage = 64`, no `storage_type` (the provider's default resolves to gp2, and the
API confirms gp2 on both), no `multi_az`, `instance_class = var.db_instance_class` (default
`db.t4g.micro`, not overridden in any environment's tfvars), `apply_immediately = true`,
`auto_minor_version_upgrade = true`, `backup_retention_period = var.backup_retention_period`
(module default 0). The staging and development tfvars set `backup_retention_period = 7`
(#414, applied 2026-11-04); production is still 0 until #415 applies. Neither instance has
Performance Insights, Enhanced Monitoring or storage encryption, and there are no CloudWatch
alarms on RDS metrics (the four alarms in `cluster-addons-layer/cloudwatch_alarms.tf` are all
ALB metrics).

| Env | Instance | Class | vCPU / RAM | Storage | Multi-AZ | Backups | AZ | Created | Instance $/h | Instance $/mo | Storage $/mo | Backup $/mo | Total $/mo | Total $/yr |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| development | none (unprovisioned) | | | | | | | | | $0 | $0 | $0 | $0 | $0 |
| staging | `terraform-20260507154835758400000003` | `db.t4g.micro` | 2 / 1 GiB | gp2, 10 GiB (autoscale to 64) | no | 7 days | us-west-1a | 2026-05-07 | $0.021 | $15 | $1 | $0 | **$17** | **$201** |
| production | `terraform-20230128225531926200000006` | `db.t4g.micro` | 2 / 1 GiB | gp2, 10 GiB (autoscale to 64) | no | 0 days (7 after #415) | us-west-1c | 2023-01-28 | $0.021 | $15 | $1 | $0 | **$17** | **$201** |
| **Total** | | | | | | | | | | **$31** | **$3** | **$0** | **$33** | **$401** |

Unrounded: $0.021 x 730 = $15.33 instance, 10 GiB x $0.138 = $1.38 storage, $16.71 per
environment, $33.42 for both, $401.04 per year.

Backups: automated backup storage is free up to 100% of allocated storage summed across the
region's instances, so 20 GiB today. The databases use about 2.6 GiB each (free storage 7.3 to
7.4 GiB of 10), staging has two automated snapshots so far, and production carries five manual
snapshots from 2024 to 2026 plus two orphan final snapshots of deleted instances (one from
2023-01, one from 2026-05). Snapshots are incremental and sized by used space, so the total is
very likely inside the 20 GiB allowance and the line is $0; the charge above the allowance would
be $0.095 per GB-month, i.e. about $1 per extra 10 GiB. **verify** in Cost Explorer under usage
type `USW1-RDS:ChargedBackupUsage` (the staging CI role has no `ce:GetCostAndUsage`). The two
orphan final snapshots and the 2024 snapshot are candidates for deletion either way.

### Unit prices used (us-west-1, PostgreSQL, on-demand)

| Item | Single-AZ | Multi-AZ |
|---|---|---|
| `db.t4g.micro` (2 vCPU, 1 GiB, 10% baseline per vCPU, 12 credits/h, 288 max) | $0.021/h = $15/mo | $0.043/h = $31/mo |
| `db.t4g.small` (2 vCPU, 2 GiB, 20% baseline, 24 credits/h, 576 max) | $0.043/h = $31/mo | $0.085/h = $62/mo |
| `db.t4g.medium` (2 vCPU, 4 GiB, 20% baseline, 24 credits/h, 576 max) | $0.085/h = $62/mo | $0.171/h = $125/mo |
| `db.t3.micro` (2 vCPU, 1 GiB, x86) | $0.024/h = $18/mo | $0.048/h = $35/mo |
| `db.t3.small` (2 vCPU, 2 GiB, x86) | $0.048/h = $35/mo | $0.095/h = $69/mo |
| `db.m7g.large` (2 vCPU, 8 GiB, smallest non-burstable Graviton) | $0.192/h = $140/mo | $0.384/h = $280/mo |
| gp2 storage | $0.138 per GB-month | $0.276 per GB-month |
| gp3 storage (baseline 3,000 IOPS / 125 MiB/s included below 400 GiB) | $0.138 per GB-month | $0.276 per GB-month |
| gp3 provisioned IOPS above baseline (only at 400 GiB and above on PostgreSQL) | $0.024 per IOPS-month | $0.048 per IOPS-month |
| gp3 provisioned throughput above baseline (same restriction) | $0.096 per MiB/s-month | $0.192 per MiB/s-month |
| Backup storage beyond the free allowance | $0.095 per GB-month | same |
| Snapshot export to S3 | $0.012 per GB | same |
| T4g surplus CPU credits (Unlimited mode) | $0.075 per vCPU-hour | same |
| CloudWatch standard-resolution alarm | $0.10 per alarm-month | |

Two things the price list settles: **gp3 is not cheaper than gp2 in us-west-1** (identical
$0.138; the "gp3 is 20% cheaper" figure is true in us-east-1 and other regions, not here), and
`db.t4g` is cheaper than the x86 `db.t3` equivalent by 12 to 15%, so there is no cheaper class
to move to. `db.t4g.micro` is the smallest RDS class orderable for PostgreSQL (there is no
`db.t4g.nano`); the floor is the floor.

## Real utilization (14 days to 2026-11-05, hourly samples)

`AWS_PROFILE=ac-ci-staging python3 -I scripts/rds_utilization_summary.py` (the staging CI role
can read CloudWatch for both instances because they share the account). "avg" is the mean of
the 336 hourly averages; "max" and "min" are the extreme hourly maximum and minimum.

| Metric | Production avg / max / min | Staging avg / max / min | Limit on `db.t4g.micro` | Reading |
|---|---|---|---|---|
| CPUUtilization (%) | 2.77 / 50.39 / 1.85 | 3.59 / 54.36 / 1.12 | 10% baseline per vCPU | Well under baseline; the 50% spikes are short (backups, autovacuum) and never dent the credit balance. |
| CPUCreditBalance | 288.00 / 288.00 / 286.34 | 288.00 / 288.00 / 286.13 | 288 max (24 h x 12/h) | Full the entire fortnight. |
| CPUCreditUsage (per 5 min) | 0.28 / 2.47 / 0.23 | 0.36 / 2.87 / 0.26 | 1.0 per 5 min at baseline | Using about a third of what it earns. |
| CPUSurplusCreditsCharged | 0 / 0 / 0 | 0 / 0 / 0 | billed at $0.075 per vCPU-h | Nothing billed. |
| FreeableMemory (MiB) | 190 / 305 / **146** | 161 / 297 / **118** | 1 GiB total; shared_buffers takes 1/4 | **The tight dimension.** 118 to 146 MiB floor on a 1 GiB box. |
| SwapUsage (MiB) | 13.5 / 16.5 / 11.2 | 14.9 / 17.4 / 1.7 | | Small, stable; not thrashing, but not zero. |
| DatabaseConnections | 1.08 / 3 / 0 | 1.07 / 3 / 0 | about 80 to 110 (`LEAST(DBInstanceClassMemory/9531392, 5000)`, **verify** with `SHOW max_connections`) | One Rails pod with `pool: 5` and `RAILS_MAX_THREADS` default 5 can open at most 5 plus migrations and psql pods. Far from the limit. |
| FreeStorageSpace (GiB) | 7.32 / 7.39 / 7.32 | 7.37 / 7.39 / 7.26 | 10 GiB allocated | About 2.6 GiB used, flat over the fortnight. |
| BurstBalance (%) | 99.1 / 100 / 99.0 | 99.1 / 100 / 99.0 | gp2 I/O credit bucket | Never spent. |
| ReadIOPS / WriteIOPS | 0.34 / 13.4 and 2.12 / 19.5 | 0.36 / 18.0 and 2.11 / 28.1 | gp2 baseline 100 IOPS, burst 3,000 | Peak total under 50 IOPS, half the gp2 baseline. |
| WriteThroughput (KiB/s) | 221 / 2,202 | 221 / 3,309 | gp2 128 MiB/s | Negligible. |
| ReadLatency / WriteLatency (ms) | 0.29 / 20.0 and 1.14 / 59.1 | 0.31 / 25.0 and 1.19 / 42.6 | gp2: single-digit ms 99% of the time | Averages are fine; hourly maxima of 20 to 60 ms are the gp2 tail. |

**Conclusion: `db.t4g.micro` has headroom** on CPU, credits, connections, IOPS and storage. The
one metric to watch is **FreeableMemory**: RDS reports Linux `MemAvailable`, which already counts
reclaimable page cache, so a floor of 118 MiB means the kernel has little left to give; swap is
in use but not growing. Nothing today suggests the memory ceiling will be hit, but it is the
reason a bump would happen, so the trigger for `db.t4g.small` should be memory-based (see
"Alarms"), not CPU-based. The 14-day window does not include a traffic spike; the app's ALB p99
alarm would show one.

## Options matrix

Monthly and yearly figures are for the whole estate (both instances) unless the option names one
environment. "Delta" is against today's $33 per month / $401 per year.

| # | Option | $/mo | $/yr | Delta $/mo | Delta $/yr | Reliability | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | Keep `db.t4g.micro`, gp2 10 GiB, single-AZ, on-demand | $33 | $401 | $0 | $0 | same | Baseline. Works today; memory is the only thin margin. |
| 2 | **gp2 to gp3 (both), which requires 10 to 20 GiB** | $36 | $434 | **+$3** | **+$33** | **better** (flat 3,000 IOPS / 125 MiB/s, no burst bucket, 2x storage and backup headroom) | **Do it.** No downtime; one modify per instance. |
| 3 | Raise allocated storage to 20 GiB but stay on gp2 | $36 | $434 | +$3 | +$33 | marginally better (same 100 IOPS baseline until 34 GiB) | Pointless without gp3. Shrinking is impossible: RDS never reduces allocated storage, and 10 GiB is already below the gp3 minimum. |
| 4 | Stop the development instance outside working hours | $33 | $401 | $0 | $0 | n/a | No dev instance exists. For reference a micro stopped 118 of 168 h/week saves $11 per month ($129 per year) minus a scheduler; storage and backups keep billing while stopped. |
| 4b | Stop staging nights and weekends | $23 | $272 | -$11 | -$129 | **worse** (staging deploys, `./go smoke staging`, TFC applies at any hour; a stopped instance cannot be modified; auto-restart after 7 days) | No. $11 per month does not pay for the pipeline breakage. |
| 5 | Multi-AZ for production (gp2 10 GiB) | $51 | $610 | **+$17** | **+$209** | **better** (standby in another AZ, automatic failover in 1 to 2 min, class changes and patches done standby-first) | Price of availability; not needed at this traffic, but this is the number. With gp3 20 GiB it is +$20 per month. |
| 6 | `db.t4g.small` for production only | $49 | $594 | **+$16** | **+$193** | better margin (2 GiB RAM, 20% baseline, 576 credits) | Only when FreeableMemory says so. A class change is a reboot with downtime (see Risks). |
| 7 | Aurora Serverless v2 with 0 ACU auto-pause for staging | $46 to $75 | $555 to $905 | +$13 to +$42 | +$154 to +$504 | mixed (Aurora storage is 6-way replicated; but resume adds 15 s connection stalls and a second engine to operate) | No. Running floor 0.5 ACU x $0.16 = $58 per month; break-even needs more than 72% paused time, which an always-on Rails pod will not deliver. Also strands any RDS RI. |
| 8 | Consolidate staging and production on one instance, two databases | $17 | $201 | -$17 | -$201 | **worse** (shared blast radius, shared maintenance window, staging load and migrations hit production) | No. The saving is $17 per month; the separation is the point of having staging. |
| 9 | Reserved instances, 2 x `db.t4g.micro`, 1-year All Upfront ($246) | $23 | $279 | **-$10** | **-$122** | same | **Do it** (or #10). Break-even 8 months. |
| 10 | Reserved instances, 2 x `db.t4g.micro`, 3-year All Upfront ($528) | $17 | $209 | **-$16** | **-$192** | same | Higher saving, 17-month break-even, bound to RDS PostgreSQL on `db.t4g` until 2029-11. |
| 2+9 | gp3 and 1-year RIs | $26 | $312 | -$7 | -$89 | better | Recommended low-regret combination. |
| 2+10 | gp3 and 3-year RIs | $20 | $242 | -$13 | -$159 | better | Recommended if a 3-year commitment is acceptable. |

## Option details

### (a) Is `db.t4g.micro` the floor, and is it adequate for production?

It is the floor: RDS offers no smaller class for PostgreSQL, and `db.t4g` is cheaper than the x86
`db.t3` at every size. Whether it is *adequate* is a question of three limits:

- **CPU credits.** A `db.t4g.micro` earns 12 credits per hour (10% baseline per vCPU, 2 vCPUs)
  and can bank 288. Both instances have been at 288 for the whole fortnight while using about
  3.4 credits per hour, so they could run at 100% of both vCPUs for 288 / (2 - 0.2) = about 2.7
  hours before touching surplus credits, and even then RDS `db.t4g` runs in Unlimited mode: it
  does not throttle, it bills $0.075 per vCPU-hour over baseline, worst case 2 x 730 x 0.9 x
  $0.075 = $99 per month if pinned all month, at which point `db.m7g.large` ($140) is the real
  answer. Today's risk of a surprise credit bill is nil.
- **Memory.** 1 GiB, of which PostgreSQL's `shared_buffers` takes a quarter
  (`DBInstanceClassMemory/32768` pages). Freeable memory floors of 118 to 146 MiB with 15 MiB of
  swap are workable for a 2.6 GiB database with 1 to 3 connections, but every additional
  connection costs several MiB and a Solid Cache or a second app replica would eat into it. This
  is the dimension that decides a bump to `db.t4g.small` (2 GiB, +$16 per month).
- **Connections.** Default `max_connections` is `LEAST(DBInstanceClassMemory/9531392, 5000)`,
  which on 1 GiB works out to roughly 80 to 110 depending on how much of the gibibyte RDS reports
  as instance memory (**verify** with `SHOW max_connections;` from `scripts/launch_psql_pod.sh`).
  The app opens at most 5 per pod (`pool: 5` in `config/database.yml`, Puma
  `RAILS_MAX_THREADS` default 5, one replica, no `WEB_CONCURRENCY` workers). Even at five replicas
  that is 25. Not a constraint.

Adequate for production reliability, then, in the sense that it is not close to any limit at the
current load. What it does not give production is any availability feature: a single instance in
one AZ, with every class change, minor version upgrade, parameter reboot and AZ event being an
outage. That is the Multi-AZ question (e), not a class question.

### (b) gp2 to gp3, and why it drags 10 GiB to 20 GiB

Today's 10 GiB gp2 volume gets the gp2 floor of 100 IOPS baseline (3 IOPS per GiB with a minimum
of 100) and 128 MiB/s, plus a burst bucket that allows 3,000 IOPS until the bucket drains. The
bucket starts full at 5.4 million I/O credits and refills at the 100 IOPS baseline, so at a
sustained 3,000 IOPS it lasts 5.4M / (3,000 - 100) = about 31 minutes, after which the volume is
pinned at 100 IOPS until it refills. The measured peak is under 50 IOPS, so `BurstBalance` has
never left 99 to 100%; this is not a current problem. It is an "it will never become a problem"
change: gp3 on RDS PostgreSQL below 400 GiB is a flat 3,000 IOPS and 125 MiB/s with no bucket,
no credits and no throttling cliff, at the same $0.138 per GB-month.

The catch is the minimum size. `describe-valid-db-instance-modifications` on the staging
instance returns gp2 as valid from 10 GiB and **gp3 only from 20 GiB** (gp3 IOPS fixed at 3,000
and throughput at 125 below the striping threshold, so `iops` and `storage_throughput` must be
left unset in Terraform or the API rejects the modify). Going to 20 GiB costs 10 x $0.138 =
**$1.38 per month per instance, $2.76 for both, $33 per year**, and brings two side benefits:
the free backup allowance rises from 20 to 40 GiB region-wide, and the `max_allocated_storage =
64` autoscaling ceiling is reached from 20 rather than 10, which matters only because RDS
autoscaling adds storage in 10% or 10 GiB steps and never removes it.

Mechanics: the modify is online. The RDS settings table lists a brief downtime for storage type
changes only to or from magnetic; gp2 to gp3 (and the size increase, "downtime doesn't occur
during this change, performance might be degraded") are done with Elastic Volumes. The instance
shows `modifying` then `storage-optimization`; while optimizing, performance is "no less than
the lower of the two specifications" and **no further storage modification is accepted until
optimization completes** (RDS also caps storage modifications at four per 24 hours; the
frequently quoted six-hour wait is the typical optimization time for small volumes, **verify**
on staging). Because `apply_immediately = true`, the change happens during the Terraform Cloud
apply, not in the maintenance window.

### (c) Backup storage cost under the current retention

With 7-day retention (staging now, production after #415) RDS keeps one daily snapshot plus
continuous transaction logs for point-in-time restore. The first snapshot is a full copy of used
space (about 2.6 GiB, not the 10 GiB allocated); each later one is incremental. Manual
snapshots count against the same allowance. With the allowance at 100% of allocated storage
across the region (20 GiB today, 40 GiB after the gp3 change) and perhaps 6 to 10 GiB of
snapshots in total, the backup line is **$0**, and even a 30 GiB total would cost (30 - 20) x
$0.095 = $1 per month. Retention could go to 14 or 35 days without noticeable cost; the figure
to keep an eye on is the transaction log volume, which is what grows with write traffic, and the
measured write throughput is 221 KiB/s average. Deleting the two orphan final snapshots from
deleted instances and the 2024 `pre-upgrades` snapshot is free housekeeping.

### (d) Stopping an instance outside working hours

Not applicable to development (no instance). For the record: `aws rds stop-db-instance` stops
instance-hour billing while storage, automated backups and manual snapshots keep billing; the
maximum stop is **7 consecutive days**, after which RDS restarts the instance by itself, so an
"off" schedule needs an EventBridge Scheduler rule or Step Functions workflow to re-stop it; a
stopped instance cannot be modified, so a Terraform Cloud apply that touches the instance fails
while it is stopped; and PostgreSQL may need crash recovery on the restart. A micro stopped 70%
of the week (nights and weekends) saves 0.7 x $15.33 = **$11 per month**. Staging is used by
deploy promotions, smoke tests and TFC applies at arbitrary hours, so this option is a net
negative there. If a dev instance is ever provisioned, the better answer is to provision it only
for the duration of the work and destroy it (`skip_final_snapshot = false` keeps the data).

### (e) Multi-AZ for production

`multi_az = true` on the existing instance creates a synchronous standby in a second AZ and
doubles the instance and storage rates: `db.t4g.micro` Multi-AZ is $0.043 per hour = **$31 per
month** and storage is $0.276 per GB-month, so production goes from $17 to $34 per month,
**+$17 per month, +$209 per year** (+$20 per month with gp3 at 20 GiB). What it buys:

- Automatic failover on instance, storage or AZ failure, typically 60 to 120 seconds, with the
  same endpoint (DNS flips).
- Class changes, OS patching and storage operations are performed on the standby first and then
  a failover, so the outage for a class change becomes the 1 to 2 minute failover rather than a
  full reboot of the only instance. Engine minor and major version upgrades still upgrade both
  nodes together and still cause downtime.
- The conversion itself is online ("downtime doesn't occur during this change, however there is
  a possible performance impact" while the standby is seeded).

What it does not buy: read scaling (the standby is not readable; that is the "Multi-AZ DB
cluster" product at $0.414 per GB-month and three instances) or protection from bad deploys
and bad migrations. At the current load and with no stated availability objective this is a
cost, not a saving, and the honest recommendation is to defer it until an SLO exists; the
number is here so that decision is explicit. Note the RI interaction: a Multi-AZ micro counts
as 1 normalized unit, so two Single-AZ micro RIs (0.5 each) cover it in full.

### (f) Consolidating staging and production onto one instance

One instance with two databases would save $17 per month. It would also put staging's
migrations, load tests, `psql` sessions, and every staging apply (storage changes, retention
changes, engine upgrades, class changes) on the same engine and the same maintenance window as
production, and the upgrade plan's whole value is that staging takes the risk first. Dismissed.

### (g) Aurora Serverless v2 with 0 ACU auto-pause

Aurora PostgreSQL Serverless v2 in us-west-1 is $0.16 per ACU-hour (standard) with a running
minimum of 0.5 ACU, plus $0.11 per GB-month of consumed storage and $0.22 per million I/Os.
With `MinCapacity = 0` the writer pauses after 5 minutes to 24 hours (configurable) with no
user connections, bills nothing for compute while paused, and resumes in about 15 seconds on the
next connection attempt (30 seconds or more after 24 hours paused). Requires Aurora PostgreSQL
16.3 or later, fine for a 16 or 18 target.

Cost at this scale for one environment: running 24x7 at the 0.5 ACU floor is 0.5 x 730 x $0.16
= **$58 per month**, plus $0.33 for 3 GB of storage, versus $17 today. Break-even against the
micro needs ACU-hours below (16.71 - 0.5) / 0.16 = 101 per month, i.e. awake less than 203 hours
of 730 (28%). The staging Rails pod runs 24x7, ActiveRecord's reaper closes idle pool
connections after 300 seconds, so the pod does not hold a permanent connection, but the hourly
`DatabaseConnections` average of 1.07 with a minimum of 0 says the database is rarely idle for
long. A realistic 50% paused figure gives about $29 per month, still nearly double today, and
every first request after a pause stalls 15 seconds. Add the operational cost (a different
Terraform resource pair, `aws_rds_cluster` plus `aws_rds_cluster_instance`, a snapshot migration
between engines, staging and production on different engines, and an Aurora PostgreSQL RI being
a separate product so any RDS RI would be stranded). Dismissed.

## Reservations

RDS has no Savings Plans; reserved DB instances are the only commitment discount, and they are
a billing construct (nothing changes on the instance or in Terraform). No RIs exist in the
account today (`describe-reserved-db-instances` is empty). Offerings below are what the RDS API
returned for this account in us-west-1 on 2026-11-05 for PostgreSQL, Single-AZ; 3-year No
Upfront is not offered for RDS. "Effective $/mo" spreads any upfront fee over the term.

### Per instance

| Class | Term and payment | Upfront | Hourly | Effective $/mo | $/yr | Total over term | Saving vs on-demand |
|---|---|---|---|---|---|---|---|
| `db.t4g.micro` | On-demand | $0 | $0.021 | $15.33 | $184 | $552 (3 yr) | 0% |
| `db.t4g.micro` | 1-yr No Upfront | $0 | $0.015 | $10.95 | $131 | $131 | 28.6% |
| `db.t4g.micro` | 1-yr Partial Upfront | $64 | $0.007 | $10.44 | $125 | $125 | 31.9% |
| `db.t4g.micro` | 1-yr All Upfront | $123 | $0 | $10.25 | $123 | $123 | 33.1% |
| `db.t4g.micro` | 3-yr Partial Upfront | $135 | $0.005 | $7.40 | $89 | $266 | 51.7% |
| `db.t4g.micro` | 3-yr All Upfront | $264 | $0 | $7.33 | $88 | $264 | 52.2% |
| `db.t4g.small` | On-demand | $0 | $0.043 | $31.39 | $377 | $1,130 (3 yr) | 0% |
| `db.t4g.small` | 1-yr No Upfront | $0 | $0.030 | $21.90 | $263 | $263 | 30.2% |
| `db.t4g.small` | 1-yr Partial Upfront | $127 | $0.015 | $21.53 | $258 | $258 | 31.4% |
| `db.t4g.small` | 1-yr All Upfront | $247 | $0 | $20.58 | $247 | $247 | 34.4% |
| `db.t4g.small` | 3-yr Partial Upfront | $269 | $0.010 | $14.77 | $177 | $532 | 52.9% |
| `db.t4g.small` | 3-yr All Upfront | $527 | $0 | $14.64 | $176 | $527 | 53.4% |

### Estate scenarios

| Estate | On-demand $/mo | 1-yr No Upfront | 1-yr Partial Upfront | 1-yr All Upfront | 3-yr Partial Upfront | 3-yr All Upfront |
|---|---|---|---|---|---|---|
| **2 x micro (today)** | $30.66/mo, $368/yr | $21.90/mo, saves $105/yr (upfront $0) | $20.88/mo, saves $117/yr (upfront $128) | **$20.50/mo, saves $122/yr (upfront $246)** | $14.80/mo, saves $190/yr (upfront $270, $533 over 3 yr) | **$14.67/mo, saves $192/yr (upfront $528; $576 over 3 yr)** |
| Production small + staging micro | $46.72/mo, $561/yr | $32.85/mo, saves $166/yr | $32.00/mo, saves $177/yr (upfront $191) | $30.83/mo, saves $191/yr (upfront $370) | $22.17/mo, saves $295/yr (upfront $404) | $21.97/mo, saves $297/yr (upfront $791) |
| 3 x micro (if dev is ever provisioned) | $45.99/mo, $552/yr | $32.85/mo, saves $158/yr | $31.32/mo, saves $176/yr (upfront $192) | $30.75/mo, saves $183/yr (upfront $369) | $22.20/mo, saves $285/yr (upfront $405) | $22.00/mo, saves $288/yr (upfront $792) |

Break-even on the upfront payment versus on-demand: 1-year All Upfront in 8.0 months; 3-year
All Upfront in 17.2 months. The production instance has existed since January 2023 and the plan
of record keeps it on RDS PostgreSQL, so the 3-year term is defensible; the 1-year term is the
low-regret default if any of the dismissed options (Aurora, a different family) might come back
within three years.

### Size flexibility and what the RI is bound to

- **Size-flexible within family, engine and region.** RDS applies RIs in normalized units per
  hour: micro 0.5, small 1, medium 2, large 4 for Single-AZ, double for Multi-AZ. A micro RI
  applied to a `db.t4g.small` covers 50% of its hours and the rest bills on-demand; two micro RIs
  cover one small, or one Multi-AZ micro, in full. Three micro RIs (1.5 units, 3-year All Upfront
  $792) cover production-on-small plus staging-on-micro exactly as well as one small plus one
  micro RI ($791). The practical rule: **buy micro RIs as the unit, and if production grows, buy
  one more micro RI rather than a small RI.**
- **Engine-bound, not version-bound.** The RI is for "PostgreSQL" and the engine version does not
  have to match, so a 3-year RI bought now outlives the 16.13 to 18.6 upgrade (#363, #364)
  without issue, and PostgreSQL 16 standard support ending 2029-02-28 is irrelevant to it.
  **Aurora PostgreSQL is a different RI product**: moving to Aurora (Serverless v2 or provisioned)
  would strand an RDS PostgreSQL RI for the rest of its term.
- **Family-bound.** `db.t4g` only; moving to `db.t3` (x86) or `db.m7g` strands it. The node-group
  arm64 migration (#409) is EKS, not RDS; the RDS instances are already Graviton.
- **Single-AZ versus Multi-AZ is flexible** in both directions by normalized units.
- **Not cancellable**, and upfront fees are billed whether or not an instance runs. Consolidated
  billing shares RIs across accounts in the organization, which does not matter here (one
  account).

## Risks and interactions

| Change | Downtime | Mechanism | Interactions |
|---|---|---|---|
| gp2 to gp3 with 10 to 20 GiB | **None** per the RDS settings table (downtime applies only to magnetic conversions). Performance "between the source and target specifications" while `storage-optimization` runs. | One `ModifyDBInstance` with `StorageType=gp3, AllocatedStorage=20`, applied immediately because `apply_immediately = true`. Cannot be undone (allocated storage never shrinks; gp3 to gp2 is allowed but pointless). | Cannot be submitted while the instance is `modifying` (backup retention change, engine upgrade) and blocks other storage changes until optimization finishes. Keep it out of the same apply as #415 and #363/#364; do it as its own PR per environment with the instance `available`. **verify** on staging how long `storage-optimization` lasts (expect minutes to a few hours for 20 GiB). Watch for the plan to show only `storage_type` and `allocated_storage` changing. |
| Instance class change (`db.t4g.micro` to `db.t4g.small`) | **Yes.** "Downtime occurs during this change": RDS provisions a new host and moves the volume. Typically 5 to 10 minutes for a small single-AZ instance (**verify**; this repo has no measurement of a class change, only the 11-second blip for the retention change in #414). | Applied at apply time, not in the maintenance window, because of `apply_immediately = true`. Default parameter group `default.postgres16` is memory-formula-based (`shared_buffers`, `max_connections`), so the new class picks up larger values on reboot with no parameter group change. | With Multi-AZ the same change would be a 1 to 2 minute failover. Do not combine with the engine upgrade in one apply. Size-flexible RIs keep applying pro rata. |
| Multi-AZ conversion | None for the conversion; performance impact during standby seeding. | `multi_az = true`, in-place modify. | After conversion every later engine upgrade still has downtime; class changes become failovers. Doubles instance and storage rates. |
| Backup retention 0 to 7 (production, #415) | About 11 seconds measured on staging, then 7 minutes `modifying`. | Already planned. | Must land before #364 (RDS pre-upgrade snapshots) and before any storage change on production (an instance in `modifying` rejects a storage modify). |
| PostgreSQL 16.13 to 18.6 (#363, #364) | Yes, planned. | Already planned. | Storage type, class and RIs are all independent of the engine version. Do the gp3 change after the upgrade in each environment so each apply has one purpose and the upgrade's pre and post snapshots are not interleaved with a storage optimization. |
| RI purchase | None. | Console or `purchase-reserved-db-instances-offering`; billing only. | Independent of all of the above. Only risk is leaving RDS PostgreSQL or `db.t4g` before the term ends. |
| Storage autoscaling to 64 GiB | None. | Already configured; RDS adds storage when free space is under 10% for 5 minutes. | Each autoscale is a storage modification subject to the same optimization lock and 4-per-24h cap. With 7.3 GiB free of 10 it is not close. |

Two things the Terraform provider will do that are worth expecting in the plan: on the gp3 PR
the `aws_db_instance` shows `storage_type: "gp2" -> "gp3"` and `allocated_storage: 10 -> 20`
in place (no replacement); on a class PR it shows `instance_class` in place. If the plan ever
shows `iops` or `storage_throughput` being set, stop: below 400 GiB the API rejects explicit
values on PostgreSQL gp3.

### Alarms (cheap, and the real answer to "when do we bump the class")

There are no RDS alarms today. Four standard-resolution alarms per instance at $0.10 each is
under $1 per month for both environments and turns the sizing question into a signal instead of
a periodic investigation. Suggested, wired to the existing `alarm_email` SNS topic in
`cluster-addons-layer/cloudwatch_alarms.tf`:

- `FreeableMemory` < 100 MiB for 3 of 5 periods (5-minute periods): the class-bump trigger.
- `CPUCreditBalance` < 100 for 2 periods: sustained burst, precursor to surplus charges.
- `FreeStorageSpace` < 2 GiB: autoscaling should handle it, but this says it is happening.
- `DatabaseConnections` > 50: something other than the app is holding connections.

`BurstBalance` becomes irrelevant on gp3 and is not worth an alarm if the gp3 change goes
ahead.

## Implementation sketch

Order: development tfvars kept in step (unprovisioned), then staging, then production, one
PR per environment, each after that environment's Phase 5 (#414/#415 retention, #363/#364 engine
upgrade) is applied and the instance is `available`. No Terraform change is needed for the
reservations.

### 1. gp3 and 20 GiB (module plus per-environment tfvars)

`terraform/modules/aws/main_rails_app/variables.tf`: two new variables, defaults equal to today's
live values so adding them is a no-op plan.

```hcl
variable "db_allocated_storage" {
  default     = 10
  description = "Allocated storage in GiB for the app database. Can only ever increase (RDS never shrinks a volume). gp3 requires at least 20."
  type        = number
}

variable "db_storage_type" {
  default     = "gp2"
  description = "RDS storage type for the app database: gp2 (legacy burst-bucket IOPS) or gp3 (flat 3,000 IOPS / 125 MiB/s below 400 GiB). Leave iops and storage_throughput unset on gp3 under 400 GiB; the API rejects them."
  type        = string
}
```

`terraform/modules/aws/main_rails_app/main.tf`, in `aws_db_instance.automation_calculator_app`:

```hcl
  allocated_storage = var.db_allocated_storage
  storage_type      = var.db_storage_type
```

Each `terraform/env/<env>/aws/us-west-1/cluster-addons-layer/`: `variables.tf` gets the same two
variables with the same defaults, `main.tf` passes `db_allocated_storage = var.db_allocated_storage`
and `db_storage_type = var.db_storage_type` to `module "main_rails_app"`, and `terraform.tfvars`
(kept sorted, `scripts/sort_tfvars.sh`) gets:

```hcl
db_allocated_storage           = 20
db_storage_type                = "gp3"
```

Expected plan per environment: one in-place update of
`module.main_rails_app.aws_db_instance.automation_calculator_app` with exactly
`allocated_storage: 10 -> 20` and `storage_type: "gp2" -> "gp3"`. Verify after apply:

```bash
aws rds describe-db-instances --region us-west-1 --query 'DBInstances[].[DBInstanceIdentifier,StorageType,AllocatedStorage,Iops,StorageThroughput,DBInstanceStatus]'
```

and wait for `DBInstanceStatus` to leave `storage-optimization` before queueing any other
change. Once both environments are on gp3, a housekeeping PR can flip the module defaults to
`20` and `"gp3"` and drop the tfvars lines (Phase 6 style).

### 2. Optional class override (only when the memory alarm says so)

The env configs do not currently expose `db_instance_class`. Add it the same way #415 added
`backup_retention_period` (env `variables.tf` with default `"db.t4g.micro"`, pass-through in
`main.tf`), then in the production tfvars only:

```hcl
db_instance_class              = "db.t4g.small"
```

Expected plan: one in-place update, `instance_class: "db.t4g.micro" -> "db.t4g.small"`. Plan
a 15-minute window; the instance reboots (**verify** the duration on staging first by applying
the same override there and reverting, which costs about $0.05 for the hour).

### 3. Buying the reservation (manual, one time, not Terraform)

The staging and production CI roles should not have `rds:PurchaseReservedDBInstancesOffering`;
do this from an SSO admin session or the console (RDS, Reserved instances, Purchase reserved DB
instance). CLI equivalent for the recommended 2 x `db.t4g.micro`, PostgreSQL, Single-AZ,
us-west-1 (offering IDs as returned on 2026-11-05; re-run the describe to confirm before
buying):

```bash
# List current offerings and confirm the price and ID
aws rds describe-reserved-db-instances-offerings --region us-west-1 \
  --db-instance-class db.t4g.micro --product-description postgresql --no-multi-az \
  --query 'ReservedDBInstancesOfferings[].[Duration,OfferingType,FixedPrice,RecurringCharges[0].RecurringChargeAmount,ReservedDBInstancesOfferingId]'

# 1-year All Upfront, $123 each (b8a0d9c8-e7d4-43f1-aa60-5deca2a39693 on 2026-11-05)
aws rds purchase-reserved-db-instances-offering --region us-west-1 \
  --reserved-db-instances-offering-id b8a0d9c8-e7d4-43f1-aa60-5deca2a39693 \
  --db-instance-count 2 --reserved-db-instance-id ac-rds-t4g-micro-2026-11

# or 3-year All Upfront, $264 each (1ba97baa-e4d7-4c93-b7d5-95d34eb9b91b on 2026-11-05)
aws rds purchase-reserved-db-instances-offering --region us-west-1 \
  --reserved-db-instances-offering-id 1ba97baa-e4d7-4c93-b7d5-95d34eb9b91b \
  --db-instance-count 2 --reserved-db-instance-id ac-rds-t4g-micro-2026-11

# Confirm
aws rds describe-reserved-db-instances --region us-west-1
```

The RI starts applying to matching usage within the hour; nothing on the instances changes.
Record the purchase and its end date here and in `docs/dependency-upgrade-plan-2026-q4.md`'s
successor so a future Aurora or family change is made knowing the RI is there.

### 4. Alarms

A small addition to `terraform/modules/aws/cluster-addons-layer/cloudwatch_alarms.tf` (or to
the `main_rails_app` module, which owns the instance and can reference its identifier) with the
four alarms above, dimension `DBInstanceIdentifier`, same SNS topic. Separate PR; no RDS
modification involved.

## Sources

Checked 2026-11-05 unless noted.

- AWS Price List bulk API, Amazon RDS, us-west-1 (version 20261029070635, published 2026-10-29),
  filtered with `scripts/rds_price_list_extract.py`:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/us-west-1/index.csv>
  (the staging CI role has no `pricing:GetProducts`, so the public CSV was used instead of the
  Pricing API).
- RDS reserved instance offerings and owned reservations for this account:
  `aws rds describe-reserved-db-instances-offerings --region us-west-1 --product-description postgresql`
  and `aws rds describe-reserved-db-instances --region us-west-1`.
- Valid storage modifications for the staging instance (gp3 minimum 20 GiB, fixed 3,000 IOPS /
  125 MiB/s below 400 GiB):
  `aws rds describe-valid-db-instance-modifications --region us-west-1 --db-instance-identifier terraform-20260507154835758400000003`.
- Live configuration and utilization: `aws rds describe-db-instances`,
  `aws rds describe-db-snapshots`, `aws rds describe-db-parameters --db-parameter-group-name default.postgres16`
  and `scripts/rds_utilization_summary.py` (CloudWatch `AWS/RDS`, 14 days to 2026-11-05, period
  3600, Average/Maximum/Minimum).
- RDS pricing page (PostgreSQL): <https://aws.amazon.com/rds/postgresql/pricing/>
- RDS reserved instances: <https://aws.amazon.com/rds/reserved-instances/>
- Reserved DB instances for Amazon RDS (offering types, size flexibility, normalization units,
  engine and family binding):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithReservedDBInstances.html>
- Amazon RDS DB instance storage (gp2 baseline 3 IOPS/GiB minimum 100, burst to 3,000; gp3
  3,000 IOPS / 125 MiB/s below 400 GiB; performance during volume modification):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html>
- Understanding burst vs. baseline performance with Amazon RDS and gp2 (5.4 million I/O credit
  bucket): <https://aws.amazon.com/blogs/database/understanding-burst-vs-baseline-performance-with-amazon-rds-and-gp2/>
- Settings for DB instances (downtime per setting: class change yes, storage type only for
  magnetic, allocated storage no, Multi-AZ no, backup retention 0 to non-zero yes; four storage
  modifications per 24 hours; no new storage request until optimization completes):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ModifyInstance.Settings.html>
- DB instance class types (db.t4g Unlimited mode):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html>
- Key concepts for burstable performance instances (t4g.micro 12 credits/h, 288 max, 10%
  baseline; t4g.small 24/576/20%; surplus credits over a 24-hour window):
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html>
- Stopping an Amazon RDS DB instance temporarily (7-day maximum, automatic restart, storage and
  backups billed while stopped, cannot modify a stopped instance):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html>
- Scaling to zero ACUs with automatic pause and resume for Aurora Serverless v2 (0 ACU minimum,
  5-minute to 24-hour idle timeout, about 15-second resume, Aurora PostgreSQL 16.3 or later):
  <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html>
- Aurora pricing (Serverless v2 ACU-hour, storage, I/O): <https://aws.amazon.com/rds/aurora/pricing/>
- This repo: `terraform/modules/aws/main_rails_app/main.tf` and `variables.tf`,
  `terraform/env/*/aws/us-west-1/cluster-addons-layer/terraform.tfvars`,
  `docs/dependency-upgrade-plan-2026-q4.md` (Phase 5, development unprovisioned),
  `plans/rate-limit-shared-cache-store.md` (prior `db.t4g.small` +$16 per month figure), PRs
  #414, #415, #363, #364, and the app's `config/database.yml` and `config/puma.rb`
  (`pool: 5`, `RAILS_MAX_THREADS` default 5).
