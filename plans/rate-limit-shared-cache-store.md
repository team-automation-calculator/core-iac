# Rate limiting: a shared cache store, when to adopt one, and what it costs

Status: **proposal** (not scheduled). Nothing below is implemented. **Trigger to act:** the app runs
more than one replica.

Prices were checked on 2026-11-04 against AWS's public price list for US West (N. California,
`us-west-1`) and the AWS pricing pages (sources at the end). Monthly figures use 730 hours and
on-demand rates, rounded to whole dollars. Anything marked **verify** could not be confirmed from a
public page or from this repo and should be checked in the AWS console before a decision.

## Summary and recommendation

- **Today costs $0 and is correct.** The app runs one replica (`replicaCount: 1`, no HPA), so Rails'
  default per-pod `FileStore` gives every request the same throttle counters. Nothing to do.
- **The trigger is replica count, not traffic.** With N pods the effective limit becomes roughly
  `configured_limit x N`, silently, so the moment `replicaCount` goes above 1 a shared store is
  required, not optional.
- **First shared store: Solid Cache on the existing RDS Postgres. Expected incremental cost: $0 to
  about $1 per month per environment** (see "Expected cost per month"). It needs no new AWS
  resources, no Terraform, and no new secret; the extra rows and writes are a rounding error on a
  db.t4g.micro at the app's throttle volume. The only scenario in which it costs real money is if
  the database is already at its limits and the cache tips it into a `db.t4g.small` bump, which is
  **+$16 per month** per environment and would be driven by app traffic, not by the cache.
- **ElastiCache later, if ever.** The cheapest always-on option is one `cache.t4g.micro` Valkey node
  at **$12 per month per environment ($37 for all three)**; with a replica for HA it is $25
  ($74 for three). ElastiCache Serverless for Valkey has a **$7 per month floor** per cache and is
  the cheapest ElastiCache shape for a near-idle cache; Serverless for Redis OSS is **$101** because
  of its 1 GB storage minimum. Running ElastiCache in production only and keeping dev and staging
  on Solid Cache is $7 to $25 per month total, but it means production exercises a code path
  (`:redis_cache_store`) that staging does not.
- **Recommendation**: stay on the per-pod file store while `replicaCount` is 1; adopt Solid Cache in
  the same PR that first scales past one replica; revisit ElastiCache only when cache throughput is
  high enough to want it off the primary database or when Redis is wanted for other reasons
  (sessions, Sidekiq, general caching).

## Why this exists

App PR #251 adds request throttling with Rails 8's built-in `rate_limit`, which counts requests in
`Rails.cache`. The app does not configure `config.cache_store`
(`config/environments/production.rb` leaves the `:mem_cache_store` line commented), so Rails falls
back to its default: an `ActiveSupport::Cache::FileStore` at `tmp/cache` inside each container.
That store is **per pod**: every replica keeps its own counters on its own ephemeral filesystem,
and nothing is shared between them.

This document records why that is fine today, the exact point at which it stops being fine, what
to switch to when that point arrives, and what each option costs per month.

## Why the per-pod file store is fine right now

- **One replica.** `helm/automation-calculator/values.yaml` sets `replicaCount: 1` and there is no
  HorizontalPodAutoscaler. With a single pod, "per-pod" and "global" are the same thing, so throttle
  counters are effectively shared.
- **Capacity is a non-issue.** A rate-limit counter is a few bytes. The file store has no size cap
  configured and the pod has no `ephemeral-storage` limit, so it is bounded only by the node's 20 GB
  EBS root volume (`disk_size = 20` in the base-cluster-layer node group) shared with the OS, the
  ~1.5 GB app image and logs. Counters will never come close to filling it.
- **Ephemerality is minor at one pod.** The cache lives on the container's writable layer and
  resets on restart or redeploy, so throttle windows briefly reset on a deploy. At one replica and
  today's traffic this is not worth engineering around.

## The point at which a shared store becomes worth it

**The trigger is replica count, not request volume directly. Volume matters only because it is
what forces more replicas.** Switch to a shared store when any of these becomes true:

1. **`replicaCount` goes above 1**, or an HPA is added, for either throughput or high availability.
   This is the real threshold.
2. **Sustained traffic** makes a single `t3.medium` pod a bottleneck (CPU, p95 latency, or memory
   pressure against the 750m / 2Gi limit), which will push you to (1).
3. **You need throttle state to survive deploys/restarts**, e.g. an abuse incident where you do not
   want a rolling deploy to hand an attacker a fresh budget.

### What breaks at more than one pod

The ALB spreads requests across pods (round-robin / least-outstanding), so a single client's
requests land on different replicas. Each replica counts only the requests it personally saw, so
the **effective limit becomes roughly `configured_limit x replica_count`**. A `10 per minute`
sign-in throttle across 3 pods lets through up to ~30 per minute per IP. The protection degrades
silently and in exact proportion to how far you have scaled out, which is precisely when you are
under enough load or attack to need it most.

Because of this, the per-pod store is not just "slightly weaker" at scale; it undoes the intent of
the throttle. That is why the trigger is binary on replica count rather than a gradual traffic
number.

## Options when the trigger fires

| Option | New infra | Shared across pods | Survives restart | Notes |
|---|---|---|---|---|
| **Solid Cache** (Rails 8, DB-backed) | none; reuses the existing RDS Postgres | yes | yes | Simplest adoption; adds cache writes to the primary DB. Good first step at low-to-moderate throttle volume. |
| **ElastiCache Valkey / Redis OSS** (node-based or Serverless) | Terraform: cluster, subnet group, SG, connection secret | yes | yes (with persistence) | The canonical shared Rails cache at scale; keeps cache load off the DB; adds cost and a module to own. Valkey is priced 20% below Redis OSS. |
| **ElastiCache Memcached** | same shape as Redis | yes | no | Fast and simple but non-durable; fine for throttle counters, weaker for general caching. Same node price as Redis OSS. |

## Expected cost per month

Working assumptions for the arithmetic: throttled endpoints see on the order of **1 request per
second on average (about 2.6 million per month)**, each `rate_limit` check is one small
read-modify-write of a key a few hundred bytes long, and keys are per (controller, client IP,
window) so the live set is tens of thousands of rows at most. This is deliberately generous for a
single-replica app; scale the per-request numbers linearly if traffic is higher.

### Solid Cache on the existing RDS instance

Each environment already pays for one single-AZ `db.t4g.micro` PostgreSQL instance
(`terraform/modules/aws/main_rails_app/main.tf`: `allocated_storage = 10`,
`max_allocated_storage = 64`, `db_instance_class` default `db.t4g.micro`, not overridden in any
env). New instances: **none, $0**. The incremental cost comes from three places:

- **Storage.** A Solid Cache row is roughly 150 to 300 bytes including its indexes, so 100,000 live
  keys is about 20 to 30 MB, and Solid Cache's default `max_age` of two weeks prunes old windows.
  The 10 GB already allocated is paid for whether or not it is used ($0.138 per GB-month x 10 GB =
  $1.38, already in the bill). Storage autoscaling only adds cost once the database exceeds 10 GB,
  and then at **$0.138 per GB-month** (gp2 and gp3 are the same price in us-west-1). Even an absurd
  1 GB of cache rows is **$0.14 per month**; the full 10 to 64 GB band would be $7.45 per month and
  cannot be driven by throttle counters. Expected: **$0.00 to $0.14**.
- **IOPS.** The instance uses the provider's default `storage_type` (gp2 when unset; **verify** on
  the live instance, since the console may show gp3). A 10 GB gp2 volume has a 100 IOPS baseline
  with burst to 3,000 from a credit bucket; gp3 has a flat 3,000 IOPS baseline. One upsert per
  second plus its WAL write is 2 to 3 IOPS, i.e. 2 to 3% of the gp2 baseline, so burst credits are
  not consumed. IOPS are not billed separately on gp2/gp3 at this size: **$0**.
- **CPU.** `db.t4g.micro` is 2 vCPU / 1 GiB, burstable, with a 10% per-vCPU baseline (**verify**:
  EC2 `t4g.micro` figure, RDS does not publish it on the price list) and runs in Unlimited mode, so
  sustained use above baseline is billed as surplus credits at **$0.075 to $0.09 per vCPU-hour**
  (both rates appear on the us-west-1 price list; **verify** which applies to PostgreSQL). A Solid
  Cache upsert costs well under a millisecond of CPU, so 1 per second is about 0.1% of one vCPU and
  50 per second is still under the baseline. Worst case, if the whole instance ran above baseline
  all month, surplus credits are capped at about 2 vCPU x 730 h x 0.9 x $0.075 = **$99**, at which
  point the right move is an instance bump, not more credits. Expected from the cache alone: **$0**.
- **Instance class bump.** `db.t4g.micro` single-AZ is $0.021/h = **$15 per month**; `db.t4g.small`
  is $0.043/h = **$31 per month**, so a bump is **+$16 per month per environment** (+$48 for all
  three). The cache will not cause this on its own; it only matters if app traffic has already
  pushed the database near its limits, in which case the bump would be needed regardless.
- **Backups.** Automated backup storage is free up to the allocated storage size (**verify**), so a
  few MB of cache rows in the snapshots cost $0.

**Expected total for Solid Cache: $0 to about $1 per month per environment** (realistically a few
cents of storage), with a **+$16 per month** contingency per environment if an instance bump is
ever attributed to it.

### ElastiCache, node-based (Valkey, Redis OSS, Memcached)

On-demand node-hour rates in us-west-1 from the AWS price list (published 2026-10-28):

| Node | Valkey | Redis OSS | Memcached |
|---|---|---|---|
| `cache.t4g.micro` (2 vCPU, 0.5 GiB) | $0.0168/h = **$12/mo** | $0.021/h = **$15/mo** | $0.021/h = **$15/mo** |
| `cache.t4g.small` (2 vCPU, 1.37 GiB) | $0.0336/h = **$25/mo** | $0.042/h = **$31/mo** | $0.042/h = **$31/mo** |

- **Single node vs. primary + replica.** A single `cache.t4g.micro` is enough for throttle counters;
  losing it for a few minutes during maintenance just resets the windows. A second node as a
  replica in the other AZ doubles the node cost (**$25** Valkey, **$31** Redis OSS for two micros)
  and enables automatic failover.
- **Valkey vs. Redis OSS.** AWS prices Valkey 20% below Redis OSS on node-based clusters, which the
  us-west-1 rates above confirm. Redis OSS versions in extended support also carry an additional
  per-hour charge ($0.017/h on `cache.t4g.micro` in years 1 to 2, $0.034/h in year 3), which Valkey
  does not. New clusters should be Valkey unless something specifically needs Redis OSS.
- **Memcached** costs the same as Redis OSS per node and has no persistence or replication, so it is
  never cheaper than Valkey here.
- **Three environments vs. production only.** One Valkey micro per environment is **$37 per month**
  for all three; primary + replica everywhere is **$74**. Production-only (dev and staging stay on
  Solid Cache) is **$12** or **$25**, but staging then no longer exercises the production cache
  store.

### ElastiCache Serverless (Valkey, Redis OSS, Memcached)

Serverless bills data stored per GB-hour plus compute in ECPUs (one ECPU covers about 1 KB
transferred by a simple command). us-west-1 rates from the price list:

| Engine | Data stored | Compute | Minimum billed storage |
|---|---|---|---|
| Valkey | $0.093 per GB-hour | $0.0025 per million ECPUs | 100 MB per cache |
| Redis OSS | $0.139 per GB-hour | $0.0038 per million ECPUs | 1 GB per cache |
| Memcached | $0.139 per GB-hour | $0.0038 per million ECPUs | 1 GB per cache |

- **Near-idle floor.** Valkey: 0.1 GB x 730 h x $0.093 = **$6.79, about $7 per month per cache**.
  Redis OSS and Memcached: 1 GB x 730 h x $0.139 = **$101 per month per cache**, because of the
  ten-times-larger minimum.
- **Compute is negligible.** 2.6 million checks per month at roughly 2 ECPUs each is 5.3 million
  ECPUs = **$0.01 per month** on Valkey; even 100 requests per second is about $1.30.
- **Compared with node-based.** Serverless Valkey (**$7**) undercuts a single `cache.t4g.micro`
  (**$12**) and is Multi-AZ by default, so for a cache this small it is the cheapest ElastiCache
  shape. Serverless Redis OSS (**$101**) is the most expensive option on this page and should not be
  chosen. Serverless scales automatically, so an abuse spike cannot exhaust a node, but it also has
  no fixed ceiling on the bill.

### Data transfer

- Pod-to-node traffic in the **same Availability Zone** over private IPs is free. Traffic that
  crosses AZs is **$0.01 per GB in each direction** (**verify** the "each direction" wording on the
  EC2 on-demand page; the ElastiCache page states $0.01 per GB for same-region traffic). The VPC
  has subnets in two AZs (`terraform/modules/aws/networking/main.tf`), so pods can land in either;
  a single-AZ node in the pods' AZ avoids the charge, a replica in the other AZ does not.
- At the assumed volume this is about 1 GB per month each way, **$0.02 per month** even if every
  request crosses AZs. Serverless charges nothing for in-region transfer to its VPC endpoint.

### Hidden and one-off costs

- **$0 AWS resources**: the Terraform module, the ElastiCache subnet group, the parameter group and
  the security group rule from the node/pod security group to port 6379 are all free.
- **Secret for the endpoint**: the app already receives `DATABASE_URL` and `SECRET_KEY_BASE` as
  Helm-rendered values from Terraform `random_password` resources, not from Secrets Manager. A
  `REDIS_URL` injected the same way is **$0**. If it were stored in Secrets Manager instead, that is
  about $0.40 per secret per month plus API calls (**verify**).
- **Engineering time** (qualitative): Solid Cache is an app-only change, roughly **2 to 4 hours**
  including the migration and a staging check. ElastiCache is a new Terraform module plus a
  plan/apply through staging and production and a Helm change, roughly **8 to 16 hours**, plus the
  ongoing ownership of one more module, one more engine to version-track and one more thing to
  patch.

### Monthly cost comparison

| Option | One env | Three envs | Production only | Note |
|---|---|---|---|---|
| Per-pod `FileStore` (today) | $0 | $0 | $0 | Only correct at `replicaCount: 1`. |
| Solid Cache on existing RDS | $0 to $1 | $0 to $3 | $0 to $1 | +$16/env if it ever forces a `db.t4g.small` bump. |
| ElastiCache Serverless Valkey | $7 | $20 | $7 | 100 MB floor; cheapest ElastiCache shape for a near-idle cache; Multi-AZ. |
| ElastiCache Valkey, 1 x `cache.t4g.micro` | $12 | $37 | $12 | Single AZ, no failover. |
| ElastiCache Redis OSS or Memcached, 1 x `cache.t4g.micro` | $15 | $46 | $15 | Same work as Valkey for 25% more. |
| ElastiCache Valkey, 2 x `cache.t4g.micro` (primary + replica) | $25 | $74 | $25 | Multi-AZ failover; replica traffic crosses AZs. |
| ElastiCache Valkey, 1 x `cache.t4g.small` | $25 | $74 | $25 | Next size up if 0.5 GiB is ever too small. |
| ElastiCache Redis OSS, 2 x `cache.t4g.micro` | $31 | $92 | $31 | As above, Redis OSS pricing. |
| ElastiCache Serverless Redis OSS or Memcached | $101 | $304 | $101 | 1 GB storage minimum dominates; do not choose. |

The recommendation that follows from this table is in "Summary and recommendation" above: Solid
Cache first ($0 to $1); if ElastiCache is ever justified, Serverless Valkey ($7) or one
`cache.t4g.micro` Valkey node ($12) per environment; never Serverless Redis OSS ($101).

## Implementation sketch

**Solid Cache (recommended first step):**
- App: add the `solid_cache` gem, generate its migration, and set
  `config.cache_store = :solid_cache_store` in `production.rb`. The migration runs through the
  existing `entrypoint.sh` (`db:migrate`) against RDS. If no separate cache database is configured,
  Solid Cache uses the `ActiveRecord::Base` connection pool, which is what we want here. No core-iac
  change.

**ElastiCache Valkey (later, if needed):**
- core-iac: a `terraform/modules/aws/elasticache` module (serverless cache or replication group, a
  subnet group in the private subnets, a security group allowing the EKS node/pod security group on
  6379) called from each env's base or addons layer; output the endpoint.
- Deploy: inject `REDIS_URL` into the app via the Helm chart (a non-secret endpoint env or a Secret),
  and set `config.cache_store = :redis_cache_store, { url: ENV["REDIS_URL"] }`.
- Keep the throttle limits the same; only the backing store changes.

## Independent of the store: see the real client IP

`rate_limit` buckets by `request.remote_ip`. Confirm the app sees the true client IP and not the
ALB's internal `10.x` address, otherwise every request shares one bucket and the throttle collapses
to a single global limit regardless of the store. This is a
`config.action_dispatch.trusted_proxies` / `X-Forwarded-For` check and should be verified on
staging whichever store is in use.

## Sources

- AWS Price List bulk API, ElastiCache, us-west-1 (version 20261028192450):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonElastiCache/current/us-west-1/index.csv>
- AWS Price List bulk API, RDS, us-west-1 (version 20261029070635):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/us-west-1/index.csv>
- ElastiCache pricing page (Serverless minimums, Valkey 20% / 33% discounts, data transfer notes):
  <https://aws.amazon.com/elasticache/pricing/>
- RDS pricing page: <https://aws.amazon.com/rds/postgresql/pricing/>
- RDS DB instance class types (db.t4g Unlimited mode):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html>
- RDS storage types (gp2 baseline/burst IOPS, gp3 baseline):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html>
- EC2 on-demand pricing, data transfer within a region:
  <https://aws.amazon.com/ec2/pricing/on-demand/>
- Solid Cache README (defaults, connection pool behaviour):
  <https://github.com/rails/solid_cache/blob/main/README.md>
