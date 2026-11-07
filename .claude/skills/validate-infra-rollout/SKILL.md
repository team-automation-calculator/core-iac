---
name: validate-infra-rollout
description: Roll out a core-iac Terraform or Helm change (provider bump, chart bump, add-on values, module refactor) through staging and then production with a before/after snapshot of each environment, the Terraform Cloud run watched to completion, and the result recorded on the PR. Use when asked to merge and validate an infra PR, verify a cluster-addons or base-cluster apply on staging or production, or check that an apply changed only what its PR body said it would.
---

# Validate an infra rollout: snapshot, merge, watch, diff, record

A `core-iac` PR says in its body what its apply should do ("Expected plan",
"Rollout", "Rollback"). This skill is the verification wrapped around merging
it: a snapshot of each environment before, the Terraform Cloud run watched to
its end, the same snapshot after, and the diff compared with what the PR
promised. It is the infra counterpart of `deploy-image`, which handles app
image bumps; use that one for a `0.9.6-<build>` promotion.

Order is always **staging first, then production**, and production only after
staging's diff matches the expectation.

## Facts you need

- **Which workspace applies what.** Each environment has
  `ac_app_<env>_base_cluster_layer` and `ac_app_<env>_cluster_addons_layer`
  in Terraform Cloud org `team-automation-calculator`. The add-ons workspace
  also owns RDS, the ACM certificate and its Route 53 validation records, the
  app namespace and Secret (module `main_rails_app`), and ArgoCD with the
  app's `Application` (module `argocd`). The app's Helm release left the
  staging workspace in ArgoCD migration Phase 6 and the production one in
  Phase 8: the app is synced by ArgoCD from `main` (automatically on
  staging, by a manual `argocd app sync` on production), `helm list` shows
  no `automation-calculator` release (only `argocd` and `argocd-apps` in
  namespace `argocd`), and a missing app release in a snapshot is expected.
  Development is intentionally
  unprovisioned: its config is validated by CircleCI only and never applies.
  Merging to `main` triggers a run in every workspace whose files changed:
  - **staging auto-applies**, usually 3–5 minutes after merge;
  - **production stops at "apply pending"** and needs a confirm in the
    Terraform Cloud UI. The user does that; this skill never does. The run
    queued by the merge embeds an EKS token that expires in about 15
    minutes, so if it is not confirmed promptly the user discards it and
    starts a fresh run, then confirms that one. Say this in the hand-off.

- **How to see a run from here.** Terraform Cloud posts a commit status for
  each workspace on the PR head (speculative plan) and on the merge commit
  (the real run). The status flips to `success` when the plan succeeds,
  which for staging means applied and for production means planned and
  waiting. The repo's `scripts/wait_commit_status.py` (run from the repo
  root) polls them through `gh`:

  ```bash
  python3 -I scripts/wait_commit_status.py <merge sha>       # one line per state change, exits when terminal
  gh api repos/team-automation-calculator/core-iac/commits/<sha>/status \
    --jq '.statuses[] | select(.context | startswith("Terraform Cloud")) | "\(.context) \(.state) \(.updated_at) \(.target_url)"'
  ```

  The plan *text* (resource counts, what changes) needs the Terraform Cloud
  API or UI. If `TFE_TOKEN` is set, read it from the run's `plan` relation
  (`GET /api/v2/runs/<run-id>` then the plan's `json-output` or
  `resource-additions/changes/destructions`). If it is not set, say so,
  give the user the run URL from the status, and ask them to read the plan
  summary against the PR's "Expected plan" before you merge; do not merge a
  change to a provisioned workspace on a plan nobody has read. A manual run
  started in the UI does not update the commit status, so after a
  discard-and-rerun on production, trust the snapshot diff, not the status.

- **Known plan artifacts.** Two things show up in `cluster_addons_layer`
  plans that are not regressions:
  1. The first plan after a helm provider 2.x to 3.x move (merged in #357)
     migrates each `helm_release` state and re-adds every `set` value, so all
     releases plan an in-place update. The apply is one no-op `helm upgrade`
     per release: revision +1, manifests identical, no pod restart.
  2. "2 to add, 2 to destroy" on the two ACM validation CNAMEs
     (`aws_route53_record.automation_calculator_app_cert_validation[...]`)
     whenever `module.cluster_addons` had pending changes. That was caused by
     a module-level `depends_on` and was fixed by #404 (2026-11-04). Since
     then a CNAME replacement in an add-ons plan is a **regression** and a
     stop, not an expected artifact.
  Anything else outside the PR's stated resources (a `helm_release`
  replacement, a chart `version` the PR did not bump, any RDS, ACM, IAM or
  VPC change) is a stop: do not merge, or if already merged, do not confirm
  production and report.

- **Timing an RDS modify.** The repo's `scripts/rds_status_poll.py <env> <log>` (run from the repo root) logs every change of each instance's status, retention and `LatestRestorableTime` (read-only, `-ro` profile), one line per change. Pair it with a 2 s `curl` loop on `/health` to bound an outage; the 2026-11-04 retention 0 → 7 apply on staging showed about 11 s of 503 one minute into the modify, then 7 more minutes of `modifying` with `/health` 200.

- **What a snapshot is.** The repo's `scripts/env_snapshot.py` (run from
  the repo root) captures, read-only, everything the morning's rollouts were
  verified with: `helm list -A` and `helm get manifest` for every release,
  pods (image, restarts, resources) in `automation-calculator`,
  `kube-system` and `default`, the host's Route 53 records (A/AAAA aliases,
  the external-dns `*-extdns.` TXT records, the ACM validation CNAME), the
  ACM certificate's status and expected validation records, and `/health`.

  ```bash
  S=scripts/env_snapshot.py
  python3 -I $S take staging    tmp/<pr>/staging-before
  python3 -I $S take staging    tmp/<pr>/staging-after
  python3 -I $S diff tmp/<pr>/staging-before tmp/<pr>/staging-after
  python3 -I $S take production tmp/<pr>/production-before [--context CTX]
  ```

  Snapshots live in the gitignored `tmp/`, one directory per PR. A check
  that fails (no kubectl context, expired SSO, forbidden) is listed in
  `errors.txt` and the rest still run; the diff says which side lacks what.

- **Read-only personas.** Every command here is a read. Use the `-ro` AWS
  profiles (`ac-ci-staging-ro`, `ac-ci-prod-ro`) and a kube context created
  with them (`ac_app_<env>-ro`); the script defaults to those. See
  `docs/aws-sso-auth.md`. Never run the SSO login yourself or switch the
  user's current context. Two limits seen in practice:
  - no `_read_only` role can read Helm release Secrets, on any environment
    (`AmazonEKSViewPolicy` excludes Secrets and the `ac-ci-read-only` group
    is bound only to a nodes ClusterRole), so `helm list` / `helm get
    manifest` need the read-write `ac-ci-<env>` role via a separate
    context. Ask before using it; a snapshot without the Helm checks is
    acceptable and the diff still covers pods, Route 53, ACM and `/health`.
    If the Helm checks seem to pass under a `-ro` context, the context is
    probably mislabeled: on 2026-11-04 `ac_app_staging-ro` was found
    embedding `AWS_PROFILE=ac-ci-staging` (cluster-admin). `env_snapshot.py`
    refuses a context whose `kubectl auth whoami` identity is not a
    `_read_only` role. The cause is a shared kubeconfig *user* entry: without
    `--user-alias`, every context on a cluster uses the one user named by
    the cluster ARN, and whichever `update-kubeconfig` ran last sets its
    profile. Recreate the `-ro` context with its own user entry and restore
    the user's current context, which `update-kubeconfig` switches:

    ```bash
    BEFORE=$(kubectl config current-context)
    aws eks update-kubeconfig --name ac_app_<env> --region us-west-1 \
      --profile ac-ci-<env>-ro --alias ac_app_<env>-ro --user-alias ac_app_<env>-ro
    kubectl config use-context "$BEFORE"
    kubectl --context ac_app_<env>-ro auth whoami    # must be ..._read_only
    ```

    (`<env>` is `staging` or `production` for the cluster, `staging` or
    `prod` for the profile.) Then pass `--context ac_app_<env>-ro` to
    `env_snapshot.py`. See `docs/aws-sso-auth.md`;
  - the permission mode may deny production reads outright. Report
    "production not inspected" and stop there; do not work around it.

- **CloudWatch alarms are part of the diff.** Production has four alarms
  on the app ALB, defined in
  `terraform/modules/aws/cluster-addons-layer/cloudwatch_alarms.tf` and
  enabled only where `cloudwatch_alarms_enabled = true` (production; staging
  has none): `ac-app-production-alb-5xx-errors` (ELB 5xx > 10 for 2 min),
  `-target-5xx-errors` (target 5xx > 10 for 2 min), `-latency-p99` (p99 > 3 s
  for 3 min) and `-unhealthy-hosts` (any unhealthy target for 2 min, on the
  target group since #425). Every ALARM and OK transition publishes to the
  SNS topic `ac-app-production-alarms`, whose email subscription has been
  confirmed since #420 (2026-11-07), so each transition is an email. Every
  read below works with `ac-ci-staging-ro` as well as `ac-ci-prod-ro`
  (CloudWatch is account-level).

  What a rollout is expected to produce:
  - add-on, values, chart or image change that replaces a pod through a
    rolling update: **no transitions**. The app Deployment keeps a Ready
    pod, so the target group never loses its only healthy host;
  - node roll (EKS upgrade, AMI release, instance type): `unhealthy-hosts`
    ALARM about 2 min after the node drains and OK about 2 min after the
    replacement target is healthy; often `alb-5xx-errors` too when the
    outage spans two minutes of 5xx. Measured 2026-11-07 (#410): 0 healthy
    hosts for 2 min, 39 ELB 5xx in one minute. These emails are the signal
    working, not a finding; report them with their times;
  - RDS modify: usually nothing (the 2026-11-07 retention change produced
    4 target 5xx in one minute, below every threshold).
  A transition the change type does not predict is a finding, and so is
  a node roll that produces none.

  Read the history for the window and the per-minute metrics behind it:

  ```bash
  aws cloudwatch describe-alarm-history --region us-west-1 --profile ac-ci-staging-ro \
    --start-date <before UTC> --end-date <after UTC> --max-records 100 --output text \
    --query 'AlarmHistoryItems[?starts_with(AlarmName,`ac-app-production`)].[Timestamp,HistoryItemType,AlarmName,HistorySummary]'
  AWS_PROFILE=ac-ci-staging-ro python3 -I scripts/alb_alarm_window.py --start <before UTC> --end <after UTC>
  ```

  `describe-alarm-history` is the authority for what fired; the replay in
  `alb_alarm_window.py` is an approximation (the live alarm looks back over
  sparse 5xx datapoints) that shows the values and the near misses. Do not
  use an alarm's `StateReason` as proof of anything: CloudWatch rewrites it
  only on a state transition, so an alarm that has stayed OK keeps its
  reason text from the last transition (or from creation) indefinitely.
  An alarm whose metric needs a dimension it does not have (the
  `unhealthy-hosts` case before #425) receives no data and never fires;
  the script prints a WARNING for that shape.

- **One account, one hosted zone.** Staging and production share AWS
  account `030153300357` and the single `automation-calculations.io` zone.
  The snapshot filters Route 53 to the environment's host, but the full
  zone dump is kept too; a change in the other environment's records during
  your window is another workspace's apply in flight (seen on 2026-11-04:
  production's validation CNAMEs deleted and recreated by #403's apply while
  staging was being baselined). Compare a surprising CNAME against the ACM
  `DomainValidationOptions` in `acm.json` before attributing it to the PR.

- **Staleness of the PR head.** A speculative plan runs on the PR head, not
  on a merge with `main`. If other add-ons PRs merged and applied after the
  head was last synced, the head's plan can show those changes being undone
  (a chart planning back to an older version). Check with
  `git log --oneline origin/<branch>..origin/main` and the Helm `UPDATED`
  timestamps against the merge times from `gh pr list --state merged`. Either
  merge `main` into the branch and wait for fresh plans, or reason explicitly
  that the merged result is "already applied" plus "this PR's expected plan",
  and say which you did.

## Procedure

1. **Read the PR.** Its "Expected plan" per workspace, "Rollout" and
   "Rollback" sections, and the test-plan checklist. Note which resources may
   change and what the apply should leave untouched. Check CircleCI and
   both Terraform Cloud statuses on the head are green, the PR is
   `MERGEABLE`/`CLEAN` (`gh pr view <n> --json mergeable,mergeStateStatus`),
   and `git merge-tree --write-tree origin/main origin/<branch>` succeeds.
   Apply the staleness check above. Read the speculative plans if a token
   is available; otherwise ask the user to.
2. **Baseline staging.** `env_snapshot.py take staging tmp/<pr>/staging-before`.
   Say what could not be captured. Do this before merging, so it is on the
   old state.
3. **Mark ready and merge** only when asked. Use `gh pr ready <n>` then
   `gh pr merge <n> --merge` (the repo uses merge commits). Record the merge
   sha and time.
4. **Watch staging.** `wait_commit_status.py <merge sha>` in the background;
   do not sleep-poll in the foreground. A `failure` or `error` status is a
   stop: report the run URL and do not touch production.
5. **Diff staging.** `take staging tmp/<pr>/staging-after`, then `diff`.
   Compare against the expectation:
   - no-op or refactor PR (state-only change such as a `terraform_data`,
     a `moved` block, a provider bump with an empty plan): every section
     identical, no new pod, `/health` 200;
   - chart or image bump: that release revision +1 and its chart version
     changed, its manifest diff limited to the bump, its pod replaced with
     0 restarts, every other release and manifest identical;
   - values change (resources, args, annotations): revision +1, manifest
     diff shows exactly those fields, pod replaced, 0 restarts;
   - helm 3.x first apply: every release revision +1 with identical
     manifests and no pod change.
   Anything outside that is a finding. Also run the PR's own staging
   test-plan items if it has them (`kubectl logs` for a sync message, a
   specific pod field). Optionally run the app smoke suite from the app
   checkout (`./go smoke staging`) when the change touches the app release,
   ingress or ALB.
6. **Hand off production.** Tell the user the production run is at "apply
   pending" with its URL, remind them of the discard-and-rerun step if more
   than ~10 minutes have passed, and wait. Before they confirm, take
   `production-before` (with the Helm limitation above) and note the time,
   which is the start of the alarm window. After their confirm, watch
   `/health` and take `production-after`, then `diff`, with the same
   expectation as staging. Then read the production alarm history for the
   window from the baseline time to the after-snapshot time and compare it
   with what the change type predicts (the alarms fact above); for a node
   roll also run `alb_alarm_window.py` over the window so the report can
   say how long the target group had no healthy host, and ask the user
   whether the ALARM and OK emails arrived.
7. **Record.** Post a comment on the PR with the result table below (the
   morning's PRs carry one each; keep the shape), including the alarms row,
   and tick the test-plan items that were actually observed, one at a time
   with a note of what was seen, where and when. Never tick an item that was
   not checked.

## Report shape

One table per environment:

| Staging (`<merge sha>`, run `<run id>`) | Result |
|---|---|
| Terraform Cloud | pending 17:59Z → success 18:04Z (auto-applied) |
| Helm releases | all revisions and chart versions unchanged — or "external-dns rev 6 → 7, chart 1.21.1 → 1.23.0, rest unchanged" |
| Manifests | identical — or "external-dns: +3 lines (`resources:` block), rest identical" |
| Pods | same pod, 0 restarts — or "external-dns pod replaced, Running, 0 restarts" |
| Route 53 (host) | identical (12 records) |
| ACM | ISSUED, validation records identical |
| `/health` | 200, `short_commit_hash` unchanged |
| CloudWatch alarms (production only) | no transitions 17:55Z to 18:05Z, as expected for a values change — or "unhealthy-hosts ALARM 17:17Z → OK 17:19Z and alb-5xx-errors ALARM 17:18Z → OK 17:20Z, matching the node roll; 0 healthy hosts 17:16Z to 17:17Z; user confirmed 4 emails" |
| Not checked | e.g. "plan text (no TFE_TOKEN); user read run-… in the UI" |

Then bullets for what the user has to do (confirm production, read a plan,
tick an item only they can verify) and anything surprising, with its cause
if found.

## Rules

- Never confirm a Terraform Cloud apply, never discard a run, and never push
  to `main`. Merge a PR only when asked to merge it.
- Never merge a change to a provisioned workspace whose plan nobody has
  read. "The status is green" is not a read plan.
- Never report an apply as good because nothing failed loudly. It is
  verified when the after-snapshot was taken after the run reached a
  terminal state and the diff matches the PR's expectation, and the report
  says so section by section.
- Keep the baseline. Take it before merging, not after; without it a
  production regression cannot be attributed.
- Reads only, read-only personas, no context switching. No `helm upgrade`,
  `rollback`, `kubectl delete`, `scale`, `edit`, `apply` or `exec` under
  any role, and no `terraform apply` from a laptop.
- A finding on staging stops the rollout before production. Report it with
  the diff, the PR's rollback section, and whether rollback is a plain
  revert or needs a state restore (provider migrations do).
