# Proposal: a shared cache store for rate limiting

**Status:** proposal (not scheduled). **Trigger to act:** the app runs more than one replica.

## Why this exists

App PR #251 adds request throttling with Rails 8's built-in `rate_limit`, which
counts requests in `Rails.cache`. The app does not configure `config.cache_store`
(`config/environments/production.rb` leaves the `:mem_cache_store` line commented),
so Rails falls back to its default: an `ActiveSupport::Cache::FileStore` at
`tmp/cache` inside each container. That store is **per pod** — every replica keeps
its own counters on its own ephemeral filesystem, and nothing is shared between
them.

This document records why that is fine today, the exact point at which it stops
being fine, and what to switch to when that point arrives.

## Why the per-pod file store is fine right now

- **One replica.** `helm/automation-calculator/values.yaml` sets `replicaCount: 1`
  and there is no HorizontalPodAutoscaler. With a single pod, "per-pod" and
  "global" are the same thing, so throttle counters are effectively shared.
- **Capacity is a non-issue.** A rate-limit counter is a few bytes. The file store
  has no size cap configured and the pod has no `ephemeral-storage` limit, so it is
  bounded only by the node's 20 GB EBS root volume (`disk_size = 20` in the
  base-cluster-layer node group) shared with the OS, the ~1.5 GB app image and
  logs. Counters will never come close to filling it.
- **Ephemerality is minor at one pod.** The cache lives on the container's writable
  layer and resets on restart or redeploy, so throttle windows briefly reset on a
  deploy. At one replica and today's traffic this is not worth engineering around.

## The point at which a shared store becomes worth it

**The trigger is replica count, not request volume directly — volume matters only
because it is what forces more replicas.** Switch to a shared store when any of
these becomes true:

1. **`replicaCount` goes above 1**, or an HPA is added, for either throughput or
   high availability. This is the real threshold.
2. **Sustained traffic** makes a single `t3.medium` pod a bottleneck (CPU, p95
   latency, or memory pressure against the 750m / 2Gi limit), which will push you
   to (1).
3. **You need throttle state to survive deploys/restarts** — e.g. an abuse
   incident where you do not want a rolling deploy to hand an attacker a fresh
   budget.

### What breaks at more than one pod

The ALB spreads requests across pods (round-robin / least-outstanding), so a
single client's requests land on different replicas. Each replica counts only the
requests it personally saw, so the **effective limit becomes roughly
`configured_limit × replica_count`**. A `10 per minute` sign-in throttle across 3
pods lets through up to ~30 per minute per IP. The protection degrades silently and
in exact proportion to how far you have scaled out — which is precisely when you
are under enough load or attack to need it most.

Because of this, the per-pod store is not just "slightly weaker" at scale; it
undoes the intent of the throttle. That is why the trigger is binary on replica
count rather than a gradual traffic number.

## Options when the trigger fires

| Option | New infra | Shared across pods | Survives restart | Notes |
|---|---|---|---|---|
| **Solid Cache** (Rails 8, DB-backed) | none — reuses the existing RDS Postgres | yes | yes | Simplest adoption; adds cache writes to the primary DB. Good first step at low-to-moderate throttle volume. |
| **ElastiCache Redis / Valkey** | Terraform: cluster, subnet group, SG, connection secret | yes | yes (with persistence) | The canonical shared Rails cache at scale; keeps cache load off the DB; adds cost and a module to own. |
| **ElastiCache Memcached** | same shape as Redis | yes | no | Fast and simple but non-durable; fine for throttle counters, weaker for general caching. |

### Recommendation

- **Stay on the per-pod file store while `replicaCount` is 1.** Do not add infra
  for a problem that does not exist yet.
- **When you first scale past one replica, adopt Solid Cache.** It reuses the RDS
  instance already provisioned by the `main_rails_app` module, needs no new
  Terraform, is shared and durable, and is a small app-only change. At the app's
  expected throttle volume the extra DB writes are negligible.
- **Move to ElastiCache Redis only if** cache throughput later becomes high enough
  that you want it off the primary database, or you adopt Redis for other needs
  (sessions, Sidekiq, general caching). At that point the shared store is a
  reusable building block, not just a rate-limit fix.

## Implementation sketch

**Solid Cache (recommended first step):**
- App: add the `solid_cache` gem, generate its migration, and set
  `config.cache_store = :solid_cache_store` in `production.rb`. The migration runs
  through the existing `entrypoint.sh` (`db:migrate`) against RDS. No core-iac
  change.

**ElastiCache Redis (later, if needed):**
- core-iac: a `terraform/modules/aws/elasticache` module (replication group or
  serverless, a subnet group in the private subnets, a security group allowing the
  EKS node/pod security group on 6379) called from each env's base or addons layer;
  output the endpoint.
- Deploy: inject `REDIS_URL` into the app via the Helm chart (a non-secret endpoint
  env or a Secret), and set
  `config.cache_store = :redis_cache_store, { url: ENV["REDIS_URL"] }`.
- Keep the throttle limits the same; only the backing store changes.

## Independent of the store: see the real client IP

`rate_limit` buckets by `request.remote_ip`. Confirm the app sees the true client
IP and not the ALB's internal `10.x` address, otherwise every request shares one
bucket and the throttle collapses to a single global limit regardless of the store.
This is a `config.action_dispatch.trusted_proxies` / `X-Forwarded-For` check and
should be verified on staging whichever store is in use.
