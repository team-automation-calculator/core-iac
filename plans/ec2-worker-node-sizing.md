# EKS worker node sizing: cost efficiency without losing reliability

Status: **proposal** (draft PR). Nothing below is implemented; no Terraform changes ride with this
document. It assumes the production arm64 migration (`docs/arm64-node-migration-plan.md`, branch
`arm64-nodes-production`) lands as planned and asks what further savings exist beyond it.

Prices were checked on 2026-11-05 against the AWS public price list for US West (N. California,
`us-west-1`, which is pricier than Oregon), the AWS Savings Plans price list for `us-west-1`
(version `20261104210253`), and the ec2instances.info dataset for the Reserved Instance terms
(sources at the end). Utilization numbers come from the live clusters on 2026-11-05 via the
`ac-ci-staging` SSO profile: `kubectl` against staging and CloudWatch EC2 metrics for both node
groups over the 14 days 2026-10-22 to 2026-11-05. Monthly figures use 730 hours, rounded to whole
dollars; hourly rates keep four decimals because the cheapest rates are under a cent. Anything
marked **verify** could not be confirmed from a public page, the API, or this repo.

## Summary and recommendation

- **There are two nodes, not three.** The development environment is intentionally unprovisioned
  (`aws eks list-clusters` returns only `ac_app_staging` and `ac_app_production`; the TFC inventory
  in `plans/tfc-to-spacelift-migration.md` says the same), so its tfvars cost nothing today. The
  node bill is **$65 per month ($785 per year)**: production `t3.medium` $36 plus staging
  `t4g.medium` $29. After the planned production move to `t4g.medium` it is **$58 per month ($701
  per year)**. Each cluster's EKS control plane is $73 per month on top, fixed and out of scope,
  and together ($146) it is more than twice the node spend.
- **The nodes are nearly idle but the shape is right.** Over 14 days both nodes averaged 3.8 to
  4.3% CPU (hourly p99 under 6%), used about 20% of the burst credits they earned, never had a
  surplus credit charged, and the staging node sits at 676 MiB of 3.2 GiB allocatable memory.
  Pod *requests*, which are what a smaller node must fit, total 820m CPU and 1,172 MiB on 9 pods.
- **Nothing non-burstable fits at a lower price.** Every Graviton `m`/`c` `.medium` (m6g, m7g,
  m8g, c7g, c8g) has 1 vCPU and a max-pods limit of 8, below the 9 pods running today, and costs
  more than `t4g.medium`. The smallest non-burstable 2-vCPU Graviton that fits (`c7g.large`,
  `m7g.large`) costs 2.3x. Burstable is the correct family here, and credit exhaustion is not a
  live risk (see "Burst credits").
- **Recommendation: keep `t4g.medium` in both environments and buy one 1-year, No Upfront EC2
  Instance Savings Plan for the `t4g` family in `us-west-1`, committing $0.0504 per hour (two
  `t4g.medium`), after production is on `t4g.medium`.** It is a billing change with no node roll
  and no reliability effect, and it is priced identically to a Standard RI (-37%) while applying
  automatically to any `t4g` size. Node cost goes from $58 to **$37 per month ($441 per year)**:
  **-$22 per month / -$259 per year** on top of the arm64 step's -$7 per month / -$84 per year.
  Against today's bill that is **-$29 per month, -$343 per year (-44%)**. The 3-year plan would be
  -$40 per month (-$482 per year) but locks a family for three years; 1 year is the right term
  given `t5g`/`m8g` churn and the open ArgoCD and EKS Auto Mode questions.
- **Right-sizing to `t4g.small` is the only bigger lever, and it is deferred.** It halves the node
  price (-$15 per month per node, -$29 per month for both; -$47 per month combined with the
  Savings Plan), keeps the same 2 vCPU and the same credit budget, and the requests fit. But it
  leaves 2 free pod slots of 11 (the ArgoCD plan needs 4), and the app's 2 GiB memory limit would
  exceed the node's ~1.45 GiB allocatable, turning any app memory leak from a pod OOM-kill into
  node memory pressure. Take it only after (a) the ArgoCD-on-cluster decision and (b) the app's
  memory limit is lowered to 1 GiB on observed usage, and fold the roll into an already-planned
  node replacement.
- **Not recommended:** two `t4g.small` nodes (same price as one `t4g.medium`, no availability gain
  while the app runs one replica, and the limit-above-allocatable problem twice), scheduling
  staging off out of hours (-$19 per month on the node, but the $73 control plane keeps running
  and the auto-apply and smoke-test workflows assume a live node), and Spot (one node, so every
  interruption is an outage).

Per-environment effect of the recommendation, node only (EBS and control plane unchanged):

| Environment | Today | After arm64 (planned) | After arm64 + 1y EC2 Instance SP | Saving vs today |
|---|---|---|---|---|
| production | $36 (`t3.medium`) | $29 | $18 | **-$18 / month, -$214 / year** |
| staging | $29 (`t4g.medium`) | $29 | $18 | **-$11 / month, -$130 / year** |
| development | $0 (no cluster) | $0 | $0 | $0 |
| **total** | **$65** | **$58** | **$37** | **-$29 / month, -$343 / year** |

## Current state

Verified on 2026-11-05 from the tfvars, the module, `aws eks describe-nodegroup` and `aws ec2`.

| Env | AMI type / arch | Instance type | vCPU / RAM | On-demand $/h | $/month (730 h) | $/year | Node group |
|---|---|---|---|---|---|---|---|
| production | `AL2023_x86_64_STANDARD` / amd64 | `t3.medium` (module default; tfvars sets no type) | 2 / 4 GiB | 0.0496 | **$36** | $435 | `primary-20260507...`, desired 1, min 1, max 2 |
| staging | `AL2023_ARM_64_STANDARD` / arm64 | `t4g.medium` | 2 / 4 GiB | 0.0400 | **$29** | $350 | `primary-93288df...` created 2026-11-05 17:27 UTC (PR #409) |
| development | `AL2023_ARM_64_STANDARD` / arm64 (tfvars) | `t4g.medium` (tfvars) | — | — | **$0** | $0 | no cluster exists |

Other node facts that matter for the options below:

- **Scaling** is `desired 1 / min 1 / max 2` in both provisioned environments: the env
  `main.tf` files override the module default of 1/1/1. `max 2` is what lets the managed node
  group surge during an AMI or version roll; it costs nothing while desired stays 1.
- **Capacity type** `ON_DEMAND`; the module sets no launch template and no credit specification,
  so the T instances run in the EC2 default **`unlimited`** credit mode (confirmed with
  `aws ec2 describe-instance-credit-specifications` for both running nodes).
- **Root volume** `disk_size = 20` GiB, which EKS provisions as gp3 (3,000 IOPS, 125 MB/s): 20 x
  $0.096 = **$2 per month per node** in `us-west-1`. Any extra node adds $2.
- **EKS control plane** $0.10 per hour = **$73 per month per cluster**, $146 for both, $1,752 per
  year. Clusters on a Kubernetes version in extended support pay $0.60 per hour ($438 per month);
  both clusters are on 1.37, in standard support.
- **Update config** `maxUnavailablePercentage = 33`.

## What actually runs on the node

Staging node `ip-10-1-157-0` (`t4g.medium`, 5 minutes after the arm64 replacement), from
`kubectl describe node` and `kubectl top`:

| | CPU | Memory | Pods |
|---|---|---|---|
| Capacity | 2000m | 3,830 MiB | 17 |
| Allocatable | 1930m | 3,288 MiB | 17 |
| Requests (sum of 9 pods) | **820m (42%)** | **1,172 MiB (35%)** | 9 used, 8 free |
| Limits | 750m | 3,028 MiB (92%) | |
| Actual (`kubectl top node`, fresh node) | 257m (13%) | 676 MiB (20%) | |

The 542 MiB gap between capacity and allocatable is EKS's reservation: kube-reserved memory
`255 MiB + 11 MiB x max-pods` (442 MiB at 17 pods) plus the 100 MiB hard-eviction threshold. The
same formula is used below to estimate allocatable on other sizes.

Per-pod requests (what a smaller node must schedule) and observed usage:

| Pod | Namespace | Replicas | CPU request | Memory request | Memory limit | Observed (`top`) | Source |
|---|---|---|---|---|---|---|---|
| automation-calculator (Rails) | automation-calculator | 1 | 250m | 512 MiB | **2 GiB** (CPU limit 750m) | 3m / 168 MiB fresh | `helm/automation-calculator/values.yaml` |
| aws-load-balancer-controller | kube-system | 2 | 50m each | 128 MiB each | 256 MiB | 2-3m / 21-26 MiB each | `cluster-addons-layer/main.tf` |
| coredns | kube-system | 2 | 100m each | 70 MiB each | 170 MiB | 2m / 13-14 MiB each | EKS default add-on |
| external-dns | kube-system | 1 | 20m | 64 MiB | 128 MiB | 1m / 17 MiB | `cluster-addons-layer/main.tf` |
| metrics-server | default | 1 | 100m | 200 MiB | none | 3m / 19 MiB | chart default |
| aws-node (vpc-cni, daemonset) | kube-system | 1 per node | 50m | 0 | none | 4m / 51 MiB (2 containers) | EKS default |
| kube-proxy (daemonset) | kube-system | 1 per node | 100m | 0 | none | 1m / 14 MiB | EKS managed add-on |

Note the app's values file requests 250m / 512Mi and *limits* 750m / 2Gi (not the other way
round). The 2 GiB limit is 12x the fresh-pod usage; the realistic steady-state Rails footprint is
a few hundred MiB **verify** (collect a 30-day `container_memory_working_set_bytes` series before
lowering it).

Pod count is the binding constraint, as `docs/argocd-migration-plan.md` already notes: 9 pods on a
17-slot node, and ArgoCD adds 4 (controller, repo-server, server, redis) with requests of about
210m / 480 MiB. Max pods on EKS without VPC CNI prefix delegation is `ENIs x (IPv4 per ENI - 1) + 2`:

| Instance | ENIs x IPs | Max pods | Headroom today (9 pods) | After ArgoCD (13 pods) |
|---|---|---|---|---|
| t4g.medium, t3.medium, t3a.medium | 3 x 6 | **17** | 8 free | 4 free |
| t4g.small, t3.small | 3 x 4 | **11** | 2 free | does not fit |
| t4g.large | 3 x 12 | 35 | 26 free | fits |
| m6g/m7g/m8g.medium, c7g/c8g.medium | 2 x 4 | **8** | **does not fit today** | no |

### 14 days of CloudWatch (2026-10-22 to 2026-11-05, by Auto Scaling group)

Collected with `scripts/ec2_worker_node_utilization.py` (read-only). The staging series is the
`t3.medium` group that was replaced on 2026-11-05; production is the `t3.medium` still running.

| Metric | staging (`t3.medium`) | production (`t3.medium`) |
|---|---|---|
| Hourly average CPU: mean / p95 / p99 / max | 3.8% / 4.1% / 5.7% / 6.6% | 4.3% / 4.6% / 5.7% / 6.3% |
| 5-minute CPU peaks: p95 / p99 / max | 24.8% / 35.2% / 38.1% | 24.7% / 34.2% / 36.2% |
| Hours with average CPU above the 20% baseline | 0 of 336 | 0 of 336 |
| CPU credits used (of 576 earned per day) | 108 per day (19%) | 123 per day (21%) |
| CPU credit balance | pinned at the 576 cap except on node-replacement days | same |
| Surplus credits charged (unlimited-mode overage) | **0** | **0** |

The 25 to 38% peaks are deploy and upgrade days (image pulls, `db:migrate`, the 1.36 to 1.37
roll on 2026-11-04). The two days where the balance dipped to ~0 are node replacements: a new
instance starts with 0 accrued credits and refills at 24 per hour, which is why "balance near
zero" is not the same as "credits exhausted" here.

## Options matrix

Per node, on-demand, `us-west-1`, 730 h. Delta is against the planned baseline of one `t4g.medium`
($29). "Fits" means the 820m / 1,172 MiB of requests schedule with the current 9 pods.

| Option | Type | vCPU / RAM | $/h | $/month | $/year | Delta vs t4g.medium | Fits requests | Max pods | Burst / credits | Reliability notes |
|---|---|---|---|---|---|---|---|---|---|---|
| **Baseline (planned)** | t4g.medium | 2 / 4 GiB | 0.0400 | **$29** | $350 | — | yes (42% CPU, 35% mem) | 17 | 20% baseline, 24 credits/h; 0 surplus in 14 d | Measured: ~2 min app outage per node roll. ArgoCD fits. |
| Current production | t3.medium | 2 / 4 GiB | 0.0496 | $36 | $435 | +$7 | yes | 17 | same credits; surplus billed at $0.05 vs $0.04 per vCPU-h | x86; being replaced. |
| x86 cheaper variant | t3a.medium | 2 / 4 GiB | 0.0446 | $33 | $391 | +$3 | yes | 17 | same | Dominated by t4g.medium; only if arm64 were abandoned. |
| **Right-size down** | t4g.small | 2 / 2 GiB | 0.0200 | **$15** | $175 | **-$15 (-50%)** | requests yes (~81% of ~1,450 MiB allocatable **verify**); app 2 GiB limit > allocatable | **11** (2 free; ArgoCD does not fit) | identical to medium (2 vCPU, 24 credits/h, 20%) | Memory headroom at requests ~280 MiB. A Rails leak hits node MemoryPressure instead of the pod limit. Same node-roll outage. |
| x86 right-size | t3.small | 2 / 2 GiB | 0.0248 | $18 | $217 | -$11 | as t4g.small | 11 | same | Dominated by t4g.small. |
| Same cost, two nodes | 2 x t4g.small (desired 2) | 2 x (2 / 2 GiB) | 0.0400 | $29 + $2 EBS | $374 | +$2 | yes, spread; but the app limit still exceeds either node's allocatable | 22 (daemonsets take 2 of each node) | each node as t4g.small | No app availability gain at `replicaCount: 1`; both nodes roll on upgrade; +150m CPU of daemonset requests on the second node; needs `desired 2 / max 3`. Only worth it with 2 app replicas + a PDB, which is a separate decision. |
| More headroom | t4g.large | 2 / 8 GiB | 0.0800 | $58 | $701 | +$29 | yes | 35 | 30% baseline, 36 credits/h | Not needed at 20% memory use. |
| Non-burstable Graviton | m7g.medium | **1** / 4 GiB | 0.0476 | $35 | $417 | +$6 | **no**: 1 vCPU (~940m allocatable vs 820m requests) and **8 max pods < 9 running** | 8 | none (fixed CPU) | Does not fit. |
| Non-burstable Graviton | m8g.medium | 1 / 4 GiB | 0.0524 | $38 | $459 | +$9 | no (same) | 8 | none | Does not fit. |
| Non-burstable Graviton | m6g.medium | 1 / 4 GiB | 0.0448 | $33 | $392 | +$4 | no | 8 | none | Does not fit; previous generation. |
| Non-burstable Graviton | c7g.medium / c8g.medium | 1 / 2 GiB | 0.0451 / 0.0496 | $33 / $36 | $395 / $434 | +$4 / +$7 | no | 8 | none | Does not fit. |
| Smallest non-burstable that fits | c7g.large / m7g.large | 2 / 4 GiB, 2 / 8 GiB | 0.0901 / 0.0952 | $66 / $70 | $789 / $834 | +$37 / +$40 | yes | 29 / 29 **verify** | none | 2.3x the price to remove a risk that has not materialized. |
| Spot | t4g.medium Spot | 2 / 4 GiB | ~0.0134 avg | ~$10 | ~$117 | -$19 | yes | 17 | same | 15 to 20% monthly interruption rate for this type; with one node every interruption is a full outage. Not acceptable for production; staging would diverge from production. |

Scaling-config changes affect cost only through node count: `max_size 2` is free at `desired 1`
and should stay (the surge during an AMI roll runs a second node for roughly 15 to 25 minutes,
about $0.02). `desired_size 2` doubles the node and EBS bill.

## Burst credits: is the T family a reliability risk here?

Both T instance types considered (`t4g.medium`, `t4g.small`) earn 24 credits per hour (2 vCPU x
20% baseline x 60 min) and bank at most 576. The measured spend is 108 to 123 credits per day, about
a fifth of what is earned, so the bank stays full and a burst can draw it down for:

- 100% CPU on both vCPUs costs 120 credits per hour, net 96 after earnings: **6 hours of a fully
  pegged node** before the bank is empty, from any starting point in the last 14 days.
- Because both nodes run in **`unlimited` mode**, an empty bank does not throttle. The instance
  keeps bursting and the account is charged surplus credits at $0.04 per vCPU-hour (T4g) or $0.05
  (T3) once the 24-hour rolling average exceeds the baseline. Worst case, 24x7 at 100%:
  1.6 vCPU-h per hour x $0.04 = $0.064 per hour, **+$47 per month** on a `t4g.medium` (+$58 on a
  `t3.medium`). That is the ceiling on the "risk", and it is a bill, not an outage.
- Break-even against the smallest non-burstable that fits (`m7g.large`, +$40 per month) is a
  sustained 24-hour average of about 89% CPU. Below that the burstable choice is cheaper even
  while paying surplus. Today's average is 4%.
- `t4g.small` has exactly the same credit numbers as `t4g.medium`, so a downsize changes nothing
  about CPU; only memory shrinks.

What "maintaining reliability" needs here is **observability, not a different family**: an alarm
on `CPUSurplusCreditsCharged > 0` (sum, 1 hour) per node group in
`terraform/modules/aws/cluster-addons-layer/cloudwatch_alarms.tf`, which today alarms only on ALB
5xx, latency and unhealthy hosts. It is a two-resource change and is the one follow-up this plan
suggests regardless of the sizing decision.

## Reservations

Prices per node. "Total" is the whole-term cost; All Upfront pays it at purchase, Partial pays
roughly half upfront and the rest hourly (**verify** the exact upfront split on the purchase
screen). Savings Plan rates were cross-checked against AWS's own `us-west-1` Savings Plans price
list and match to the fourth decimal.

### `t4g.medium` (recommended type), on-demand $0.0400/h = $29/month = $350/year

| Commitment | $/h | $/month | Total over term | Saving |
|---|---|---|---|---|
| On-demand | 0.0400 | $29 | $350 / 1y | — |
| 1y Standard RI: No / Partial / All Upfront | 0.0252 / 0.0240 / 0.0235 | $18 / $18 / $17 | $221 / $210 / $206 | -37% / -40% / -41% |
| 3y Standard RI: No / Partial / All Upfront | 0.0173 / 0.0160 / 0.0150 | $13 / $12 / $11 | $455 / $420 / $395 | -57% / -60% / -62% |
| 1y Convertible RI: No / Partial / All Upfront | 0.0339 / 0.0322 / 0.0316 | $25 / $24 / $23 | $297 / $282 / $277 | -15% / -20% / -21% |
| 3y Convertible RI: No / Partial / All Upfront | 0.0230 / 0.0212 / 0.0209 | $17 / $15 / $15 | $604 / $558 / $548 | -43% / -47% / -48% |
| **1y EC2 Instance Savings Plan: No / Partial / All** | **0.0252** / 0.0240 / 0.0235 | **$18** / $18 / $17 | **$221** / $210 / $206 | **-37%** / -40% / -41% |
| 3y EC2 Instance Savings Plan: No / Partial / All | 0.0173 / 0.0160 / 0.0150 | $13 / $12 / $11 | $455 / $420 / $394 | -57% / -60% / -63% |
| 1y Compute Savings Plan: No / Partial / All | 0.0339 / 0.0322 / 0.0316 | $25 / $24 / $23 | $297 / $282 / $277 | -15% / -20% / -21% |
| 3y Compute Savings Plan: No / Partial / All | 0.0230 / 0.0213 / 0.0208 | $17 / $16 / $15 | $604 / $560 / $547 | -43% / -47% / -48% |

### `t3.medium` (current production type), on-demand $0.0496/h = $36/month = $435/year

Listed for completeness; do not buy anything for `t3` while the arm64 migration is in flight.

| Commitment | $/h | $/month | Total over term | Saving |
|---|---|---|---|---|
| 1y Standard RI / EC2 Instance SP, No Upfront | 0.0312 | $23 | $273 | -37% |
| 3y Standard RI / EC2 Instance SP, No Upfront | 0.0214 | $16 | $562 | -57% |
| 1y Compute SP / Convertible RI, No Upfront | 0.0419 | $31 | $367 | -15% |
| 3y Compute SP / Convertible RI, No Upfront | 0.0285 | $21 | $749 | -43% |

### `t4g.small` (deferred right-size), on-demand $0.0200/h = $15/month = $175/year

| Commitment | $/h | $/month | Total over term | Saving |
|---|---|---|---|---|
| 1y EC2 Instance SP / Standard RI, No Upfront | 0.0126 | $9 | $110 | -37% |
| 3y EC2 Instance SP / Standard RI, No Upfront | 0.0086 | $6 | $226 | -57% |
| 1y Compute SP, No Upfront | 0.0169 | $12 | $148 | -16% |

### Which commitment, and why

- **The price list collapses into two tiers.** A Standard RI and an EC2 Instance Savings Plan cost
  the same; a Convertible RI and a Compute Savings Plan cost the same. Within each pair the Savings
  Plan is strictly more convenient (a dollar-per-hour commitment that applies automatically; no
  instance-count bookkeeping, no marketplace), so the RI column is only there to show nothing is
  lost by skipping it.
- **EC2 Instance Savings Plan** (-37% for 1 year): locked to one family (`t4g`) in one region
  (`us-west-1`), but flexible across size, OS and tenancy within it. It survives
  `t4g.medium` -> `t4g.small` or `t4g.large`, which are the only resizes this cluster plausibly
  makes. It does not survive a move to `m8g`, another region, or Fargate.
- **Compute Savings Plan** (-15% for 1 year, -43% for 3): applies to any EC2 family or region,
  Fargate and Lambda. It is the hedge if a family change is likely inside the term. For two
  `t4g.medium` the 1-year Compute plan saves $9 per month against the Instance plan's $22; the
  $13 per month gap is the price of that flexibility.
- **Term.** One year. The 3-year Instance plan saves a further $12 per month, but the arm64
  migration itself shows how often the family can change (the `t4g.small` free-trial generation
  `t5g`, `m8g`, EKS Auto Mode's own node pricing are all plausible within three years).
- **Timing and sizing.** Savings Plans bill the committed amount every hour whether or not usage
  covers it, so: buy only after production is running `t4g` (today the production node is `t3`,
  which a `t4g` plan would not cover), and only after the `medium` vs `small` decision, sized to
  what actually runs: $0.0504/h for 2 x `t4g.medium`, $0.0252/h for 2 x `t4g.small`. The console's
  Savings Plans recommendations tab will propose the same figure once it has 7 to 30 days of
  `t4g` production usage **verify**. One plan covers both clusters because both live in account
  `030153300357`. During a node roll the second, temporary node bills at on-demand.
- **All three environments qualify in principle** (24x7 usage), but development has no cluster.
  If it is ever provisioned, add $0.0252/h to the plan rather than scheduling it off: an
  office-hours schedule (12 h x 5 days = 261 h per month) would save $19 per month on a
  `t4g.medium` node but the $73 control plane keeps running, Terraform Cloud applies and the
  `deploy-image` smoke tests assume a live node, and a plan and a schedule cannot be combined
  (the commitment is paid for the stopped hours). The same arithmetic rules out scheduling
  staging off.
- **`t4g.small` free trial.** AWS's 750 free `t4g.small` hours per month until 2026-12-31 would
  make one `t4g.small` node free for the remaining two months (about $29 total). It applies to one
  instance per account and not to `medium`; not a reason to resize.

## Risks, and what "maintaining reliability" means per option

Current reliability: one node per environment, managed node group surge on upgrade, and a measured
1 to 2 app outages of about 2 minutes per node roll (control plane 7 to 10 minutes, node roll 13
to 14 minutes for the 1.36 to 1.37 upgrade). No option below may make that worse.

| Risk | Savings Plan only (recommended) | `t4g.small` | 2 x `t4g.small` | non-burstable `.medium` |
|---|---|---|---|---|
| Node roll outage | none: no node change | one extra ~2 min outage unless folded into the arm64 roll | two nodes roll per upgrade; app outage unchanged at 1 replica | n/a (does not fit) |
| App OOM behaviour | unchanged: pod limit 2 GiB < allocatable 3.2 GiB, kubelet kills the pod | **regresses**: limit 2 GiB > ~1.45 GiB allocatable; a leak ends in node MemoryPressure and eviction ordering decides what dies | same on each node | n/a |
| CPU credit exhaustion | unchanged; unlimited mode, 0 surplus in 14 d, ~6 h of 100% burst banked | identical credit budget to medium | each node has its own 576 bank | eliminated, at 2.3x the price for a 2-vCPU type |
| Max pods | 17, 8 free, ArgoCD fits | **11, 2 free, ArgoCD does not fit** (its preflight requires 4 free) | 22 total | 8, already over |
| Surge during AMI roll | unchanged (`max 2`) | unchanged | needs `max 3` | n/a |
| Billing lock-in | $0.0504/h for 12 months on `t4g` in `us-west-1` (~$37/month committed) | none | none | none |
| Capacity at roll time | n/a | `t4g.small` offered in `us-west-1a` and `us-west-1c`, the two AZs the subnets use (checked 2026-11-05); `instance_types` is a list, so `["t4g.small", "t4g.medium"]` lets EKS fall back | same | `m7g`/`m8g`/`c7g`/`c8g.medium` offered in both AZs |

Preconditions before `t4g.small` can be reconsidered, in order:

1. Decide whether ArgoCD runs on the cluster (`docs/argocd-migration-plan.md`). If yes, `small` is
   out unless VPC CNI prefix delegation is enabled, which raises max pods to 110 on Nitro types
   but is a vpc-cni configuration change with its own rollout **verify**.
2. Lower the app memory limit to 1 GiB (and possibly the request to 384 MiB) in
   `helm/automation-calculator/values.yaml` on 30 days of observed working-set memory, so the pod
   limit is below the small node's allocatable and the kubelet, not node pressure, bounds a leak.
3. Drop the ALB controller to 1 replica (two on one node buys nothing, as the ArgoCD plan notes)
   to recover a pod slot.

## Implementation sketch

### Recommended: Savings Plan, no Terraform change

1. Land the production arm64 PR (`arm64-nodes-production`) as planned. Its tfvars diff is the
   whole node change:
   ```hcl
   # terraform/env/production/aws/us-west-1/base-cluster-layer/terraform.tfvars
   ami_type                  = "AL2023_ARM_64_STANDARD"
   node_group_instance_types = ["t4g.medium"]
   ```
2. After production has run `t4g.medium` for at least a week (so the recommendation engine agrees
   and there is no pending rollback), purchase in the console (Billing and Cost Management ->
   Savings Plans -> Purchase): **EC2 Instance Savings Plan, instance family `t4g`, region US West
   (N. California), 1-year term, No Upfront, hourly commitment $0.0504**. There is no Terraform
   resource for purchasing a Savings Plan **verify**, and it is a one-time account-level action,
   so it is documented here and in the PR that closes this plan rather than in code.
3. Record the purchase (plan ID, commitment, expiry 12 months out) in this file's Status line and
   add a calendar reminder two months before expiry to re-run `scripts/ec2_worker_node_pricing.py`
   and renew or resize.
4. Follow-up PR: `CPUSurplusCreditsCharged` and `CPUCreditBalance` alarms in
   `cluster-addons-layer/cloudwatch_alarms.tf`.

### Deferred: `t4g.small` right-size, if the preconditions are met

Exact tfvars lines, rolled dev -> staging -> production:

```hcl
# terraform/env/development/aws/us-west-1/base-cluster-layer/terraform.tfvars  (unprovisioned; keep in step)
node_group_instance_types = ["t4g.small"]

# terraform/env/staging/aws/us-west-1/base-cluster-layer/terraform.tfvars
node_group_instance_types = ["t4g.small"]

# terraform/env/production/aws/us-west-1/base-cluster-layer/terraform.tfvars  (together with the arm64 lines)
ami_type                  = "AL2023_ARM_64_STANDARD"
node_group_instance_types = ["t4g.small"]
```

Run `scripts/sort_tfvars.sh` and `terraform fmt -recursive terraform/`. The plan must show exactly
one `aws_eks_node_group` replacement (`instance_types` is `ForceNew`); the module's
`create_before_destroy` builds the new group, waits for the node to join, then drains the old one.
That drain is the same ~2 minute app outage as an AMI roll, which is why a resize should **ride
along with a node roll that is already scheduled** (for production, the arm64 replacement; for
staging, the next AMI or version bump) rather than earn its own outage. Soak staging for a week
watching `kubectl top node`, `CPUSurplusCreditsCharged`, pod evictions and the ALB alarms before
touching production. Then re-size the Savings Plan commitment to $0.0252/h if one has been bought,
or buy it at that figure if not.

## Sources

Checked 2026-11-05 unless noted.

- AWS EC2 on-demand price map, US West (N. California), Linux:
  `https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/US%20West%20(N.%20California)/Linux/index.json`
  (t3.small 0.0248, t3.medium 0.0496, t3a.medium 0.0446, t4g.small 0.0200, t4g.medium 0.0400,
  t4g.large 0.0800, m6g.medium 0.0448, m7g.medium 0.0476, m8g.medium 0.0524, c7g.medium 0.0451,
  c8g.medium 0.0496, c7g.large 0.0901, m7g.large 0.0952)
- AWS EBS price map (`.../meteredUnitMaps/ec2/USD/current/ebs.json`): gp3 storage $0.096 per
  GB-month in US West (N. California)
- AWS Savings Plans price list, `us-west-1`, version `20261104210253`:
  `https://pricing.us-east-1.amazonaws.com/savingsPlan/v1.0/aws/AWSComputeSavingsPlan/current/region_index.json`
  and the `versionUrl` it gives for `us-west-1` (Compute and EC2 Instance plan rates for
  `USW1-BoxUsage:t4g.medium`, `t3.medium`, `t4g.small`, `m7g.medium`)
- ec2instances.info / Vantage dataset `https://instances.vantage.sh/instances.json`, `pricing["us-west-1"].linux`
  (Standard and Convertible RI effective hourly rates, all payment options; Savings Plan rates
  cross-checked against the AWS file above; spot averages and interruption bands). The per-instance
  web pages on that site show `us-east-1` prices regardless of the `region` query parameter, so
  they were not used.
- AWS EKS pricing page `https://aws.amazon.com/eks/pricing/`: $0.10 per cluster-hour standard
  support, $0.60 extended support
- AWS EC2 on-demand pricing page, "T2/T3/T4g Unlimited Mode Pricing": surplus credits $0.05 per
  vCPU-hour (T2/T3) and $0.04 per vCPU-hour (T4g) for Linux
- AWS EC2 User Guide, "Key concepts for burstable performance instances"
  (`burstable-credits-baseline-concepts.html`): credits per hour, accrual caps, 20%/30% baselines,
  T3/T3a/T4g launch in `unlimited` by default
- EKS max pods: `ENIs x (IPv4 addresses per ENI - 1) + 2`, with ENI and IP counts from
  `aws ec2 describe-instance-types` on 2026-11-05 (t4g.medium 3 x 6, t4g.small 3 x 4, t4g.large
  3 x 12, m-/c-family `.medium` 2 x 4); kube-reserved memory `255 MiB + 11 MiB x max-pods`
  (EKS AMI `bootstrap.sh`/nodeadm), matched against the observed 3,288 MiB allocatable
- `aws ec2 describe-instance-type-offerings --location-type availability-zone` in `us-west-1`
  on 2026-11-05: t4g.small, t4g.medium, t4g.large, m6g/m7g/m8g.medium, c7g/c8g.medium, t3.small,
  t3a.medium all offered in `us-west-1a` and `us-west-1c`
- CloudWatch `AWS/EC2` metrics by `AutoScalingGroupName` for both node groups, 2026-10-22 to
  2026-11-05, via `scripts/ec2_worker_node_utilization.py`
- `kubectl describe node`, `kubectl top nodes`, `kubectl top pods -A --containers` on
  `ac_app_staging`, 2026-11-05 17:33 UTC
- `aws eks describe-nodegroup` (staging), `aws ec2 describe-instance-credit-specifications`,
  `aws ec2 describe-volumes`, `aws autoscaling describe-auto-scaling-groups`, 2026-11-05
- `docs/arm64-node-migration-plan.md`, `docs/argocd-migration-plan.md`,
  `plans/tfc-to-spacelift-migration.md` (development cluster unprovisioned), and the measured
  1.36 to 1.37 upgrade timings from 2026-11-04/05
