# CloudWatch alarms

Verified: 2026-11-26

The alarms are defined in `terraform/modules/aws/cluster-addons-layer/cloudwatch_alarms.tf` behind
`cloudwatch_alarms_enabled`, which only production sets. Staging has no alarms and no alarm topic.

| Alarm | Notes |
|---|---|
| `ac-app-production-alb-5xx-errors` | Fired during the EKS 1.37 roll (2026-11-05) and the PostgreSQL 18 upgrade (2026-11-26); after the upgrade it stayed in ALARM about 10 min past the last 5xx |
| `ac-app-production-target-5xx-errors` | The RDS retention apply (2026-11-07) produced 4 target 5xx, not enough to fire |
| `ac-app-production-latency-p99` | |
| `ac-app-production-unhealthy-hosts` | Never received data until #425 (2026-11-07): the target-group host counts are published only with a `TargetGroup` dimension. Fired and cleared during the PostgreSQL 18 upgrade |

## Gotchas

- **`StateReason` is not evidence that an alarm receives data.** CloudWatch rewrites
  `StateReason` and `StateUpdatedTimestamp` only on a state transition, so the unhealthy-hosts
  alarm still read "no datapoints were received" after #425 fixed it. Check with
  `aws cloudwatch get-metric-statistics` using the alarm's exact dimensions.
- **Replay a window with `./go alb-alarm-window`** to see which alarm would have fired; it also
  warns about a host-count alarm without the `TargetGroup` dimension. When the replay and
  `describe-alarm-history` disagree, trust the history: live alarms evaluate sparse 5xx datapoints
  differently.
- **AWS deletes an unconfirmed email subscription after 3 days.** Alarm mail went nowhere until
  #420 (2026-11-07) fixed and confirmed the address; see [plan-artifacts.md](plan-artifacts.md).
- The unhealthy-hosts alarm finds its target group by the ALB controller's stack tag, so the
  Ingress name and namespace must not change (`AGENTS.md`, "Values layering").
