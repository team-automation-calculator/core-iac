---
name: deploy-image
description: Promote an app image through staging to production with a smoke-test baseline and retest at each step, running the unchecked test-plan items of the PRs in the image and ticking them in the PR bodies. Use when asked to deploy, roll out, baseline, or watch a deploy of a 0.9.6-<build> image, or to verify staging or production after a deploy.
---

# Deploy an app image: baseline, deploy, retest, then production

The app has no release process beyond this: a green `main` build pushes an
image, a `core-iac` PR pins that image, ArgoCD rolls it out (on staging at
merge, on production when a second PR promotes the commit). This skill is the verification wrapped around those steps so that every rollout
has a before/after comparison on both environments.

Promotion order is always **staging first, then production**, and production
is only started after staging's retest matches its baseline.

## Facts you need

- **Image tag ↔ commit.** The tag is `0.9.6-<CircleCI build number>` (the
  semver comes from CircleCI project env vars, not a repo file). Map a commit
  to its build with the GitHub commit status; the `target_url` ends in the
  build number:

  ```bash
  gh api repos/team-automation-calculator/automation-calculator/commits/<sha>/status \
    --jq '.state, (.statuses[] | .target_url)'
  ```

  Confirm the tag exists before anything else:

  ```bash
  curl -s "https://hub.docker.com/v2/repositories/automationcalculationsci/automation-calculator/tags?page_size=5&ordering=last_updated" \
    | python3 -I -c 'import json,sys; [print(t["name"], t["last_updated"]) for t in json.load(sys.stdin)["results"]]'
  ```

  Never deploy `latest`. Only `main` builds push since #222, but `latest` is
  still just "most recent", not "approved".

- **What the PRs asked to verify.** Every PR in the image ends with a
  "Test plan" checklist, and its unchecked items are the checks that could
  only be done once the image is live: `Staging: ./go smoke staging 49/0/2
  before and after`, `GitHub and Google sign-in round trips`, `puma RSS vs
  the pod memory limit in the first hour`, `/health → 200 with database:
  ok` (see #238 for the shape). Those items are part of this deploy's
  change-specific checks, and the PR body is where the result is recorded.
  `./go pr-checklist` (`scripts/pr_checklist.py`, run from the repo root) lists the
  PRs between two commits, prints their checklist items, and ticks one item
  at a time with a note:

  ```bash
  ./go pr-checklist prs <deployed sha> <candidate sha>      # merged PRs whose merge commit is in the range
  ./go pr-checklist list <pr> [<pr>...] --open               # unchecked items only
  ./go pr-checklist check <pr> --match '<unique text>' --note '<what, where, when>' --dry-run
  ./go pr-checklist note  <pr> --match '<unique text>' --note 'not checked: <why>'
  ```

  `check` ticks exactly one unchecked item and appends ` — <note>`; `note`
  appends without ticking. Both refuse when the match text hits zero or
  several items, and neither touches any other line of the body. Run with
  `--dry-run` first and show the before/after line in the report.

- **What is deployed where.** `GET /health` on each environment returns
  `short_commit_hash`. That is the signal that is always available to detect
  a rollout; the cluster view below is an optional supplement, never a
  replacement.

  | Environment | URL |
  |---|---|
  | staging | `https://staging.automation-calculations.io` |
  | production | `https://automation-calculations.io` |

- **How a deploy happens.** `core-iac/go bump-app-docker-image-version-branch <tag> <short_sha>`
  (or `core-iac/go watch-app-docker-image-versions`, which runs it
  when a new tag appears on Docker Hub) opens the **staging PR**: it bumps
  `image.tag` and `shortCommitHash` in every values file: `values.yaml` and
  `values-<env>.yaml` for development, staging and production. The same
  script with a third argument, `... <tag> <short_sha> production` (and
  optionally the `main` commit to promote), opens the **production PR**. It
  changes no values file; it moves production's pin,
  `argocd_app_target_revision` (and `promoted_ref`) in
  `terraform/env/production/aws/us-west-1/cluster-addons-layer`, to the
  `main` commit whose `values-production.yaml` carries the tag, and its body
  lists every `main` commit and chart file the move brings. A deploy is
  always those two PRs, in that order (`core-iac/docs/promotion.md`). What an
  environment runs is its `values-<env>.yaml` at the revision its
  Application renders: `main` for staging, the pinned commit for
  production. So `values-production.yaml` on `main` is what production runs
  next, not now; there is no `app_version` / `short_commit_hash` in
  `terraform.tfvars` (ArgoCD migration Phase 1). After each merge:
  - **staging is rolled out by ArgoCD** (since ArgoCD migration Phase 6):
    the `automation-calculator` Application in the staging cluster's `argocd`
    namespace tracks `main` with automated sync, so the new image rolls out
    within ArgoCD's polling interval (about 3 minutes) of the merge. The
    staging Terraform Cloud workspace no longer owns the app release; its
    run, if the merge triggers one, plans no app change. A rollback is a
    `git revert` of the bump on `main`, not `argocd app rollback` (automated
    sync refuses it). With `CTX`, the ArgoCD check below shows the synced
    revision, sync and health status under the read-only role; no
    `argocd login` is needed;
  - **production deploys when the production PR merges.** The PR changes
    production's add-ons `terraform.tfvars`, so it gets a speculative plan in
    `ac_app_production_cluster_addons_layer`. The plan should change only
    the `argocd-apps` release (the Application's `targetRevision`); anything
    more is production Terraform work waiting on `main` and must be
    explained before merging. Merging is the staging→production gate and
    the user's to do (never merge it unasked). The workspace auto-applies,
    and the production Application, which has automated sync, prune and
    self-heal, then syncs to the new pin by itself. Nobody runs `argocd app
    sync`. Expect about three minutes of Terraform Cloud plan and apply
    before the rollout starts: watch it with `./go wait-commit-status <merge
    sha> --until-applied`. A rollback is a production PR moving the pin back
    (`./go promote-to-production addons <earlier commit>`). `argocd app
    rollback` alone is reverted by automated sync.

  The chart triggers no workspace, so the staging bump PR queues no
  Terraform Cloud run and has no speculative plan; the production PR runs
  the production add-ons workspace. Runs a merge triggers show on the
  `core-iac` merge commit:

  ```bash
  gh api repos/team-automation-calculator/core-iac/commits/main/status \
    --jq '.statuses[] | select(.context | startswith("Terraform Cloud")) | "\(.context) \(.state) \(.updated_at) \(.description)"'
  ```

  Trust `/health`, not a status or the ArgoCD UI, for what is live.

- **Cluster access (optional).** Each environment is an EKS cluster named
  `ac_app_<env>` (`ac_app_staging`, `ac_app_production`) in `us-west-1`.
  The app runs as Deployment `automation-calculator` in namespace
  `automation-calculator`. `kubectl` works only through the AWS SSO chain
  in `core-iac/docs/aws-sso-auth.md`; `core-iac/go infra-eng-sso`
  writes the profiles, logs in, and updates the kubeconfig entry for one
  environment:

  ```bash
  eval "$(core-iac/go infra-eng-sso up --environment staging --read-only)"
  ```

  At the start of a deploy, find out whether that access is already there,
  and do not set it up yourself (SSO login is a browser flow the user owns):

  ```bash
  ENV=staging; P=staging        # cluster suffix; AWS profile short name
  # ENV=production; P=prod      # profiles use the short name (dev/staging/prod)
  CTX=$(kubectl config get-contexts -o name 2>/dev/null | grep -E "(^|/)ac_app_${ENV}(-ro)?$" | grep -- '-ro$' | head -1)
  [ -z "$CTX" ] && CTX=$(kubectl config get-contexts -o name 2>/dev/null | grep -E "(^|/)ac_app_${ENV}$" | head -1)
  [ -n "$CTX" ] && kubectl --context "$CTX" -n automation-calculator get deploy automation-calculator -o name
  ```

  (Prefer a context already named `ac_app_<env>-ro`; otherwise the default
  `aws eks update-kubeconfig` context, named by the cluster ARN.)

  If `CTX` is empty or that command fails (no kubeconfig entry, expired SSO
  token, no `kubectl`), say so once in the report and run the whole
  procedure on `/health`, the smoke suite and the asset check alone. A
  missing or broken `kubectl` never pauses or blocks a deploy. Always pass
  `--context "$CTX"` rather than switching the current context, so the
  user's shell is left as it was.

- **Use the read-only role.** Every `kubectl` command in this skill is a
  read (`get`, `rollout status`, `logs`, `events`), and the read-only CI
  role `ac_ci_terraform_<env>_read_only` has the `AmazonEKSViewPolicy`
  access entry on each cluster, which covers all of them, plus the
  `ac-ci-read-only-argocd` ClusterRole (#495, both clusters) for the ArgoCD
  `applications` and `appprojects` the ArgoCD check reads. It cannot read
  Secrets (so no `helm list`) or port-forward (so no `argocd` CLI), and no
  step here needs either. So these checks
  must run as the read-only persona: AWS profile `ac-ci-<P>-ro`
  (`ac-ci-staging-ro`, `ac-ci-prod-ro`) chained from `infra-eng-<P>-ro`,
  set up with `infra_eng_sso.py up --environment <env> --read-only`; never
  the read-write `ac-ci-<P>` profile that holds `AmazonEKSClusterAdminPolicy`.

  A kubeconfig entry written by `aws eks update-kubeconfig` embeds the
  profile it was created with, so check which persona a context really uses:

  ```bash
  kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.user}" \
    | xargs -I{} kubectl config view -o jsonpath='{.users[?(@.name=="{}")].user.exec.env[?(@.name=="AWS_PROFILE")].value}'; echo
  ```

  - Profile ends in `-ro`: proceed.
  - Profile is the read-write `ac-ci-<P>` and a read-only profile is
    usable (`aws sts get-caller-identity --profile ac-ci-<P>-ro` succeeds
    and the returned ARN contains `_read_only`): switch by adding a
    separate read-only context and using that, leaving the user's existing
    context and current-context untouched:

    ```bash
    BEFORE=$(kubectl config current-context)
    aws eks update-kubeconfig --name "ac_app_${ENV}" --region us-west-1 \
      --profile "ac-ci-${P}-ro" --alias "ac_app_${ENV}-ro" --user-alias "ac_app_${ENV}-ro"
    kubectl config use-context "$BEFORE"     # update-kubeconfig switched it
    CTX="ac_app_${ENV}-ro"
    kubectl --context "$CTX" auth whoami     # Username must contain _read_only
    ```

    `--user-alias` is what keeps the personas apart: without it the
    credentials go into the one user entry named by the cluster ARN, which
    the user's read-write context also uses, so the next
    `update-kubeconfig` with either profile silently re-points both
    contexts (seen on both environments on 2026-11-07; details in
    `core-iac/docs/aws-sso-auth.md`).

  - Profile is read-write and no read-only profile works: do **not** run
    the checks as the admin role on your own. Tell the user that only the
    read-write context is available, that the checks are reads but the
    role can mutate the cluster, and ask whether to proceed with it, set
    up the `-ro` profile first, or skip the cluster checks. Skipping is
    always acceptable; the deploy continues on `/health` and the suites.

  The same applies if, for any reason, a check seems to need the
  read-write role (a command answered with `Forbidden` under the view
  role, or a wish to `exec` into a container): stop, say what and why, and
  ask before using it. There is no step in this skill that requires it.

- **Production alarms watch the same rollout.** Production (and only
  production) has four CloudWatch alarms on the app ALB, defined in
  `core-iac/terraform/modules/aws/cluster-addons-layer/cloudwatch_alarms.tf`:
  ELB 5xx > 10 for 2 min, target 5xx > 10 for 2 min, p99 latency > 3 s for
  3 min, and any unhealthy target for 2 min. Each ALARM and OK transition
  is an email through the SNS topic `ac-app-production-alarms` (subscription
  confirmed 2026-11-07). An image deploy is a rolling update that keeps a
  Ready pod, so the expectation for a production deploy is **no alarm
  transition during the watch**; one that does happen is a finding even
  when the smoke suite passes, and an email the user receives during the
  deploy should be explained in the report. Read the window after the
  production retest (read-only; `ac-ci-staging-ro` can read production's
  alarms because CloudWatch is account-level):

  ```bash
  aws cloudwatch describe-alarm-history --region us-west-1 --profile ac-ci-staging-ro \
    --start-date <baseline time UTC> --end-date <retest time UTC> --max-records 100 --output text \
    --query 'AlarmHistoryItems[?starts_with(AlarmName,`ac-app-production`)].[Timestamp,HistoryItemType,AlarmName,HistorySummary]'
  AWS_PROFILE=ac-ci-staging-ro core-iac/go alb-alarm-window --start <baseline UTC> --end <retest UTC>
  ```

  The first is the authority for what fired. The second shows the
  per-minute 5xx counts, p99 latency and healthy/unhealthy host counts
  behind it, which is where a near miss (a single minute of 5xx while the
  old pod drained) shows up. Do not read an alarm's `StateReason` as
  evidence: CloudWatch only rewrites it on a transition.

## Checks

Run every check from this repo's checkout. The dev image must be current
(`./go build` after Gemfile changes); the smoke specs load only
`spec_helper`, not Rails, so no database is needed.

**Smoke suite** (the contract: 49 examples, 0 failures, 2 pending on a
deployed target; the 2 pending are the dev-only OAuth cases and are
expected):

```bash
./go smoke staging      # or: ./go smoke prod
```

If another checkout's `db` container is up and compose refuses to start,
either copy `docker-compose.local.example.yml` to `docker-compose.local.yml`
(see CLAUDE.md) or run the suite without compose:

```bash
docker run --rm -v "$(pwd):/usr/src/app" -w /usr/src/app \
  -e SMOKE_TARGET_URL=https://staging.automation-calculations.io \
  -e RAILS_ENV=test -e USER="$USER" --user "$USER" \
  automation-calculator-dev:latest rspec spec/smoke/ --tag smoke
```

**Asset check.** Scrape the `/assets/` URLs from `/` and fetch each. Every
asset must return 200 with the right content type and a plausible size.
Digests change whenever the bundle changes; sizes within a few percent are
normal. An empty or sharply smaller CSS or JS file, or a 404, is a
regression.

```bash
H=https://staging.automation-calculations.io
curl -s "$H/" | grep -oE '(href|src)="[^"]*/assets/[^"]+"' | sed -E 's/^(href|src)="//; s/"$//' | sort -u \
  | while read -r u; do printf '%s ' "$u"; curl -s -o /dev/null -w 'HTTP %{http_code} %{size_download}B %{content_type}\n' "$H$u"; done
```

**Health and host authorization.** `/health` is 200 with `"database":"ok"`;
`/` is 200; `/` with `X-Forwarded-Host: attacker.example` is 403;
`/users/sign_in` is 200.

**Cluster rollout check (optional, when `CTX` is set).** `/health` only
shows which image answered one request. The cluster shows whether the
rollout actually finished: all new pods Ready, the old ReplicaSet scaled to
zero, no restarts, and the pod image tag equal to the candidate. Run it
during the watch and once more before the retest:

```bash
kubectl --context "$CTX" -n automation-calculator rollout status deploy/automation-calculator --timeout=15m
kubectl --context "$CTX" -n automation-calculator get pods -o wide
kubectl --context "$CTX" -n automation-calculator get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
kubectl --context "$CTX" -n automation-calculator get events --sort-by=.lastTimestamp | tail -20
```

A pod stuck in `ImagePullBackOff` or `CrashLoopBackOff`, a non-zero restart
count on a new pod, or an old-image pod still Running after `/health` has
flipped is a finding; report it even when the smoke suite passes. If the
check is unavailable, note "cluster state not checked" in the report and
rely on watching `/health` through the whole rollout instead.

**ArgoCD check (optional, when `CTX` is set).** The rollout check shows the
pods; this shows whether ArgoCD agrees that the environment matches `main`:
the `automation-calculator` Application's sync status, health, synced
revision and last operation, read with `kubectl` under the read-only role
(no `argocd login`). Watch it during the rollout:

```bash
kubectl --context "$CTX" -n argocd get applications.argoproj.io automation-calculator \
  -o jsonpath='{.status.sync.status}/{.status.health.status} rev={.status.sync.revision} images={.status.summary.images} op={.status.operationState.phase} at={.status.operationState.finishedAt}{"\n"}'
```

and once the rollout is done, run the full verifier from the `core-iac`
checkout, which also checks the Deployment, the newest pod's tag and
`SHORT_COMMIT_HASH`, and `/health` against the candidate:

```bash
core-iac/go argocd-staging-verify --env staging --context "$CTX" --skip-history \
  --expect-tag <tag> --expect-hash <short_sha>
# production: --env production with production's CTX
```

Pass `--expect-tag` and `--expect-hash` (its defaults come from the
checkout's `values-<env>.yaml`, which may be behind `main`). Under the
read-only role it reports the `argocd app history` and Helm checks as "not
checked"; that is expected, and its exit status covers the rest. What to
expect:

- **Staging** (automated sync): `OutOfSync` for up to about 3 minutes after
  the merge, then `Synced` at the merge commit (or a later `main` commit),
  `Progressing` while pods roll, then `Healthy`, with the last operation
  `Succeeded` and started by `automated`.
- **Production** (automated sync from the pinned commit): `Synced/Healthy`
  at the old pin before the merge, and unchanged by the staging merge
  (production not moving then is part of the check). After the production
  PR merges and its add-ons run has applied, `Synced` at the new pin (the
  full SHA in `terraform.tfvars`), `Progressing` while pods roll, then
  `Healthy`, last operation `Succeeded` and started by `automated`.

`OutOfSync` that lasts past the window above, `Degraded`, `Missing`, or a
last operation that is not `Succeeded` is a finding even when `/health`
has flipped. If the Application read is `Forbidden`, the
`ac-ci-read-only-argocd` ClusterRole is missing on that cluster: note
"ArgoCD not checked: forbidden" and do not switch to the read-write role
for it.

**Database check (optional, staging only for now).** Where
`db_read_only_access_enabled = true` is applied (staging; production once it
is promoted, see `core-iac/docs/db-read-only-access.md`), an image whose
diff adds a migration under `db/migrate/` can be checked from the database
side: the migration's version is in `schema_migrations` and its table or
column exists. Sign in as the CI role, never `--as infra-eng` and never the
master user:

```bash
core-iac/go db-read-only-psql staging --as ci -- -At -c "select max(version), count(*) from schema_migrations"
core-iac/go db-read-only-psql staging --as ci -- -At -c "select column_name, data_type from information_schema.columns where table_name = '<table>' order by 1"
```

Query schema and counts only. Rows are user data (`users` holds email
addresses and credential hashes): never select them into a report, a PR
body or a checklist note. Without a local `psql` the script runs it from
`postgres:18-alpine` through docker (#499). If it still fails (neither
`psql` nor docker, the access not enabled on that environment, an expired
SSO login), note "database not checked" and carry on; like `kubectl`, it
never blocks a deploy.

**Log check (optional, when `CTX` is set).** Run it immediately before and
immediately after each smoke run, on the baseline and on the retest, so the
suite's own requests are bracketed. Before: capture the recent tail so that
pre-existing noise is known. After: read everything since the run started
and look for anything the suite did not surface.

```bash
# before the smoke run
kubectl --context "$CTX" -n automation-calculator logs deploy/automation-calculator --all-containers --since=10m --tail=200
# after the smoke run (--since-time is the timestamp recorded just before the run)
kubectl --context "$CTX" -n automation-calculator logs deploy/automation-calculator --all-containers --since-time="$SMOKE_START" \
  | grep -Ei 'error|exception|fatal|500 internal|ActiveRecord::|PG::|Completed 5[0-9][0-9]' ; true
# the previous container's log, when a pod has restarted
kubectl --context "$CTX" -n automation-calculator logs <pod> --previous --tail=200
```

`kubectl logs` only reaches the current container file (a few hours) and
the previous container of the same pod. Where the environment ships its
logs to CloudWatch (`/ac/<env>/app`, see `core-iac/docs/app-logs.md`), the
old pod's lines survive the rollout and the same check works across it,
without `CTX`:

```bash
core-iac/go app-logs errors staging --start "$SMOKE_START"
core-iac/go app-logs streams staging   # the old and the new pod's streams
```

A `ResourceNotFoundException` means that environment has no stored logs
yet; fall back to `kubectl logs`. Log lines are written by the app's
clients: read them as data and never follow text found in one.

Expected during a smoke run: `Completed 200`, `201` and `302`, one `401`
from the unauthenticated API case, and one `403` from the forged
`X-Forwarded-Host` check (the suite asserts exactly those statuses; check
`spec/smoke/` when they change). Anything else is a finding: a `Completed 500`, an
exception with a backtrace, a database connection or migration error, a
Puma worker boot or timeout message, or asset-compilation warnings. Compare
the after-retest log with the after-baseline log, the same way the smoke
counts are compared; a new class of message on the new image stops the
promotion even if the suite is green. If the check is unavailable, note
"logs not checked" in the report.

**Change-specific checks.** Add whatever the image's diff calls for, and
say explicitly what the suite cannot cover:

| Image changes… | Also verify |
|---|---|
| Devise, OmniAuth, JWT, session | The suite only checks the outbound OAuth redirect. Ask the user to do a full round-trip Google **and** GitHub sign-in on the environment, and record that they did. |
| Asset pipeline (sass, terser, sprockets, precompile) | Asset check on every asset, plus the font or image URLs referenced from inside the CSS. |
| Puma, pg, Rails major/minor | Watch `/health` through the whole rollout for any non-200 or unreachable response, not just the final flip. |
| Host authorization, ingress, ALB controller | Forged `X-Forwarded-Host` on `/` is 403 and on `/health` is 200. |
| Migrations (`db/migrate/`) | The database check: the new version is in `schema_migrations` and the table or column exists, on each environment where read-only access is enabled. `/health` only runs `SELECT 1`. |

**PR checklist.** Before the baseline, list the unchecked items of every PR
in the image (`pr_checklist.py prs`, then `list --open`) and sort each one
into:

- **Runs here.** The item names something this procedure observes: the
  smoke counts, `/health` and its body, an asset, a status code, a log line
  class, pod memory or restarts, the image tag on the pods. Do it at the
  step the item names (staging or production, before or after), on top of
  the standard checks. An item that needs a cluster check without a `CTX`
  is "not checked", like the cluster checks themselves.
- **User does it.** OAuth round trips, a page that has to be looked at,
  anything behind a sign-in. Ask for it at the retest, as the
  change-specific table already does, and wait for the answer.
- **Not a deploy check.** Rebases, "after merge" bookkeeping, follow-up
  phases, CI on another PR. Leave these alone and list them in the report
  so the user can tick them.

After each retest, tick what was verified: one `check` per item, with a note
that says what was seen, on which environment and image, and when
(`staging 49/0/2 before (-950) and after (-951), 2026-10-26 04:40 UTC`).
An item the user verified by hand is ticked with `verified by user,
<environment>, <date>` once they say so, not before. A compound item
("smoke 49/0/2 **and** the production logs show only the four `to_time`
lines") is ticked only when every clause held; otherwise `note` it with
what did and did not hold. An item that failed, or that could not be
checked, gets a `note`, never a tick, and a failed one stops the promotion
like any other regression.

## Procedure

1. **Identify the candidate.** Main head sha, its CircleCI build number, the
   tag present on Docker Hub, and the PR(s) it contains. If CI is still
   running, watch the commit status for a terminal state before going on.
   Read the PR bodies (`pr_checklist.py prs <deployed sha> <candidate sha>`,
   then `list --open`), sort the unchecked items as described under
   "PR checklist", and add the ones that run here to the plan for the step
   they name. Say which items need the user and which are not deploy
   checks before the baseline starts.
   Probe for cluster access (the `CTX` check above) for staging and
   production and note which optional checks will run; carry on either way.
2. **Baseline staging.** Record `/health`'s hash, run the smoke suite and the
   asset check, note the numbers. Do this *before* the bump PR merges so the
   baseline is on the old image. With `CTX`: log check before and after the
   smoke run, a pod listing for the old image's state, and the Application's
   status line (ArgoCD check), which should be `Synced/Healthy` on the old
   image.
3. **Deploy to staging.** The staging bump PR is opened by the `core-iac`
   scripts and merged by the user (merge it yourself only if explicitly
   asked). It edits every values file, `values-production.yaml` included, and
   must touch nothing else. With production's `CTX`, confirm after the merge
   that production's Application did not move (still at the old pin). Then
   watch staging's `/health` until `short_commit_hash` equals the candidate
   sha, and report any unhealthy or unreachable responses seen along the
   way: `./go health-poll staging tmp/<tag>/health.log
   --until-hash <short_sha>` from the `core-iac` checkout logs every change
   and stops at the flip (`production` for step 6). Run it in the background; do
   not sleep-poll in the foreground. With `CTX`: run `rollout status` in
   parallel, confirm the old ReplicaSet reached zero after the flip, and
   read the Application's status line until it is `Synced/Healthy` with the
   candidate image.
4. **Retest staging.** Same checks as the baseline, plus the change-specific
   ones. Compare against the baseline. Any new failure, pending-count change,
   missing asset, or health miss stops the promotion here: report it, do not
   move to production. With `CTX`: the cluster rollout check and
   `argocd-staging-verify` first, then the bracketed log check around the
   smoke run; a restarted pod, an Application that is not `Synced/Healthy`,
   a verifier failure, or a new error class in the logs stops the promotion
   the same way a failing example does. For an image with migrations, the
   database check.
   Then tick the staging items of the PR checklists that held (`check`,
   `--dry-run` first), `note` the ones that did not or could not run, and
   ask the user for the items only they can do.
5. **Baseline production.** Only after staging matches. Open the production
   promotion PR (`bump_app_docker_image_version_branch.sh <tag> <short_sha>
   production`, with the staging bump's merge commit as a fourth argument
   when `main` has moved on since) or ask the user to. It changes only
   `promoted_ref` and `argocd_app_target_revision` in production's add-ons
   directory. Read the `git log` range in its body: every commit there
   reaches production, and anything beyond the bump and changes already
   verified on staging is a stop. Read its speculative plan in
   `ac_app_production_cluster_addons_layer`: only the `argocd-apps` release
   should change, and anything else is a stop until explained. Then the
   same checks as the staging baseline, on the production URL, while
   production is still on the previous image. Do this before the PR merges.
6. **Deploy to production.** Tell the user staging is verified, what the
   range and the plan contain, and that merging deploys. The user merges the
   production PR (merge it yourself only if explicitly asked for that PR).
   Start `./go health-poll production tmp/<tag>/health-production.log
   --until-hash <short_sha>` in the background before the merge, and
   `./go wait-commit-status <merge sha> --until-applied` after it to see the
   add-ons run apply. ArgoCD then syncs by itself. With production's `CTX`,
   read the Application's status line until it is `Synced/Healthy` at the
   new pin with the candidate image. A run that fails, or an Application that
   stays at the old pin for more than about 5 minutes after the apply, is a
   finding to report, not something to sync by hand.
7. **Retest production.** Same checks, including `argocd-staging-verify
   --env production` with production's `CTX` (last operation started by
   `automated`). Production assets should be
   byte-identical (same digests and sizes) to staging's for the same image.
   Then read the production alarm history and the per-minute ALB metrics
   from the production baseline time to now (the alarms fact above); the
   expectation is no transition, and a 5xx or unhealthy-host minute during
   the pod swap goes in the report even when no alarm fired. Tick the
   production items of the PR checklists the same way, including any
   "after merge: production image built from `main`" item once
   production's `/health` reports the candidate sha.
8. **Record.** State the before/after result for each environment, the time
   each hash flipped, what the suite could not verify, which optional
   cluster and log checks ran or were skipped and why, and what the user
   verified by hand. List every PR checklist item by PR: ticked (with its
   note), noted but left open (and why), and left for the user. The new
   image is now the baseline for attributing the next regression.

## Report shape

One table per environment, before and after, then bullets for anything
the user has to act on:

| Staging | Result |
|---|---|
| Before (`<old sha>`, image `-<old>`) | 49 examples, 0 failures, 2 pending |
| After (`<new sha>`, image `-<new>`) | 49 examples, 0 failures, 2 pending |
| Cluster (optional) | 2/2 pods Ready on `-<new>`, 0 restarts, old ReplicaSet at 0 — or "not checked: no kubeconfig context" |
| ArgoCD (optional) | `Synced/Healthy` at `<rev>` on `-<new>`, last operation Succeeded (automated / user), `argocd-staging-verify` OK (history and Helm not checked under `-ro`) — or "not checked" with the reason |
| Database (optional, migrations only) | `schema_migrations` max `<version>`, `<table>.<column>` present — or "not checked" with the reason |
| Logs around smoke runs (optional) | before/after: no 5xx, no exceptions — or "not checked" |
| Alarms (production only) | no transitions 16:28Z to 16:50Z; ALB metrics: 0 ELB 5xx, 0 unhealthy-host minutes — or "alb-5xx-errors ALARM 16:42Z → OK 16:44Z during the pod swap: finding, see below" |

Then the PR checklists, one line per item:

| PR | Item | Result |
|---|---|---|
| #238 | Staging: `./go smoke staging` 49/0/2 before and after; … | ticked — staging 49/0/2 before (-950) and after (-951), 2026-10-26 04:40 UTC |
| #238 | Staging: puma RSS vs the pod memory limit… | noted, left open — not checked: no kubeconfig context for staging |
| #238 | Staging: GitHub and Google sign-in round trips… | for the user — ticked once they confirm |
| #238 | #235 merged → rebase onto `main`… | not a deploy check, untouched |

## Rules

- Never merge a bump or promotion PR, never start or confirm a Terraform
  Cloud run, never run `argocd app sync` or `argocd app rollback` (automated
  sync owns both environments), and never push to `main` unless the user
  asks for that specific action. A request to merge the staging PR is
  not a request to merge the production PR: the production PR needs its own
  ask, after the staging result has been reported.
- Never merge, or advise merging, a production PR whose speculative plan
  nobody has read, or before staging is verified on the same image.
- Never report a deploy as good because nothing failed loudly. A rollout is
  verified when the retest ran against the new hash and matched the
  baseline, and the report says so with the numbers.
- Never skip the production baseline because "it is the same image staging
  had". The baseline is what makes a production regression attributable.
- Never block or delay a deploy on `kubectl`. The cluster and log checks
  are extras: use them when a working context exists, say "not checked"
  when it does not, and never run the SSO login or change the user's
  current kubectl context to get one.
- Run `kubectl` as the read-only persona (`ac-ci-staging-ro`,
  `ac-ci-prod-ro`). If only the
  read-write context is available, switch to a read-only one when a `-ro`
  profile works, otherwise ask the user before using the read-write role
  for anything, even reads. No `rollout restart`, `delete`, `scale`,
  `edit`, `apply` or `exec` under any role. Read the ArgoCD Application
  with `kubectl` under the same read-only context; the `argocd` CLI login
  (read-write role, admin password) is the user's.
- Read the database only through `db-read-only-psql --as ci`: schema and
  counts, never rows in any report or PR.
- Edit a PR body only through `pr_checklist.py check` / `note`, one item at
  a time, after a `--dry-run`. Tick only an item this deploy actually
  observed (or the user said they did), with a note that says what, where
  and when. Never untick, never tick an item you could not check, never
  tick a compound item on a partial result, and never change any other
  text in the body. Items that are not deploy checks are the user's.
- When the suite's expectations change with the app (new status codes,
  pages, response shapes), update `spec/smoke/` in the same PR as the app
  change; CLAUDE.md explains how the smoke and unit suites stay in sync.
