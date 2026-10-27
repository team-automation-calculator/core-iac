# ArgoCD migration Phase 7: prove and soak the new deploy path on staging

Companion to Phase 7 of `argocd-migration-plan.md`. After Phase 6, staging deploys through ArgoCD
alone: the `automation-calculator` Application tracks `main` with automated sync, prune and
self-heal, and the staging TFC workspace no longer manages the Helm release. This phase proves
that with real traffic through the real path (a bump PR, a revert PR) and then lets it soak long
enough to trust it on production. Nothing in this phase changes Terraform or the chart; the only
cluster writes are ArgoCD's own syncs of merged PRs.

The two rules for the whole phase: **nothing is done by hand that a merge should do** (a manual
`argocd app sync`, a `kubectl` edit, a Helm command, all count as manual intervention and restart
the soak clock), and **every cycle is recorded** in `docs/argocd-staging-soak-log.md` so the gate
in section 7 is auditable rather than remembered.

## 1. Tooling

Both scripts are read-only against the cluster.

- `scripts/argocd_staging_verify.sh [--env staging] [--expect-tag TAG] [--expect-hash HASH]`
  checks that a merged PR reached staging through ArgoCD: Application Synced / Healthy, last
  operation `Succeeded` and started by `automated`, Deployment image tag and rollout complete,
  newest pod's image tag and `SHORT_COMMIT_HASH`, `GET https://<ingress.host>/health`, the tail
  of `argocd app history`, and `helm -n automation-calculator list` empty. The expected tag and
  hash default to `image.tag` and `shortCommitHash` in `helm/automation-calculator/values-staging.yaml`
  of the checkout you run it from, so run it from `main` after pulling the merge. It exits
  non-zero on any mismatch. It needs `kubectl` (the staging context), `argocd` (logged in through
  the port-forward), `yq` and `curl`; `ARGOCD_SERVER` and `ARGOCD_OPTS` default to
  `localhost:8080` and `--plaintext`.
- `scripts/argocd_soak_log.py add ...` appends a cycle to `docs/argocd-staging-soak-log.md`;
  `scripts/argocd_soak_log.py status` evaluates the gate (section 7), rewrites the log's Gate
  section and exits 0 on PASS, 1 on FAIL. Commit the log after each cycle (its own small PR, or
  folded into the next bump PR). `--file tmp/x.md` points either subcommand at a scratch copy.

## 2. Before the first cycle

- Phase 6 "Done when" holds: `helm -n automation-calculator list` empty, Application on
  `Automated (Prune), Self Heal`, Synced, Healthy, a fresh staging plan shows 0 changes.
- `main` and the cluster agree: with the port-forward and login from
  `argocd-phase-2-install.md` section 4 open,

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # SSO login, kubeconfig, AWS_PROFILE
kubectl config current-context                                # must be the ac_app_staging cluster
git checkout main && git pull
scripts/argocd_staging_verify.sh | tee tmp/phase7-00-baseline.txt   # Verify OK at the current tag
argocd app history automation-calculator                      # note the latest ID: the next cycle is ID+1
```

- A new app image exists on Docker Hub to bump to (`scripts/watch_app_docker_image_versions.py`
  prints the newest tags and whether a bump is pending). A cycle needs a real new image; never
  bump to a tag that is not on Docker Hub (CI's `validate_app_docker_image_versions` rejects it
  anyway).
- Know what a bump PR does to the **other** workspaces while Phase 8 is pending: the bump script
  edits all four values files, so `ac_app_production_cluster_addons_layer` still plans **1 to
  change** (its Helm release, as today) and waits for a confirm. That is the normal production
  deploy of today; confirm it promptly or discard it deliberately, but do not leave it waiting
  (an unconfirmed run blocks later production runs). Staging plans 0 changes, which is the point
  of this phase. Development has no cluster and fails at `data.aws_eks_cluster` as before.

## 3. A bump cycle, step by step

1. **Open the bump PR** from a clean `main` checkout, either by hand or through the watcher:

   ```bash
   scripts/bump_app_docker_image_version_branch.sh <tag> <short_commit_hash>   # branch, commit, push, PR
   scripts/watch_app_docker_image_versions.py                                  # or: poll Docker Hub and do the above
   ```

   CI runs `validate_app_docker_image_versions` on the PR. Review the diff: exactly `image.tag` and
   `shortCommitHash` in the four values files.

2. **Merge** and note the merge time:

   ```bash
   gh pr view <number> --json mergedAt,mergeCommit --jq '{mergedAt, sha: .mergeCommit.oid}'
   ```

3. **Wait for the poll.** ArgoCD polls the repo every 3 minutes by default (`timeout.reconciliation`
   in `argocd-cm`; there is no webhook), then syncs because the Application is automated. Watch
   without touching anything:

   ```bash
   argocd app get automation-calculator          # OutOfSync -> Syncing -> Synced; Progressing -> Healthy
   kubectl -n automation-calculator get pods -w  # new pod Running and Ready (startup probe: up to 3 min), old pod Terminating
   ```

   `argocd app get --refresh` asks the controller to re-read the repo now instead of at the next
   poll. It is a cache refresh, not a sync, and does not count as manual intervention; still,
   prefer to wait at least once so the default poll is what gets proven. **Do not run
   `argocd app sync`** during a cycle: it would deploy the same thing, but it is a manual sync
   (the history entry's `initiatedBy` becomes your username) and the cycle must be logged with
   manual intervention `yes`.

4. **Verify** from the updated `main` (so the expected tag and hash come from the merged file):

   ```bash
   git checkout main && git pull
   scripts/argocd_staging_verify.sh | tee tmp/phase7-cycle-<n>-verify.txt
   ```

   Expected: `Verify OK`, last operation `Succeeded, started by automated`, the newest pod carries
   the bumped tag and `SHORT_COMMIT_HASH`, `/health` returns 200, the history tail ends in a new ID
   at the merge commit, Helm list empty. Time to sync for the log is the operation's `finished`
   timestamp minus `mergedAt` from step 2.

5. **Confirm the staging TFC workspace planned 0 changes** for that merge: in the TFC UI,
   `ac_app_staging_cluster_addons_layer`, the run triggered by the merge commit says
   `Plan: 0 to add, 0 to change, 0 to destroy` and finished without an apply. The workspace still
   queues a run because `helm/automation-calculator` is in `cluster_addons_layer_module_directories`
   until Phase 9. Anything other than 0 changes on staging is a finding: do not continue the soak
   until it is understood (section 6). Handle the production run per section 2.

6. **Record the cycle** (section 5).

## 4. The real rollback test (once, early in the soak)

A bad deploy on staging is now a **git revert synced by ArgoCD**. `argocd app rollback` is refused
while automated sync is on (the Phase 3 dry run demonstrated the refusal), and that is intended:
`main` stays the single source of truth. Do this test after the first successful bump cycle so the
revert has something real to undo.

```bash
git checkout main && git pull
git checkout -b revert-bump-<tag>
git revert <merge commit sha of the bump PR>      # restores the previous image.tag + shortCommitHash in all four values files
git push -u origin revert-bump-<tag>
gh pr create --title "Revert app image bump to <tag>" --body "Phase 7 rollback test: ArgoCD syncs the revert."
```

CI passes (the previous tag still exists on Docker Hub). Merge, note `mergedAt`, wait for the poll
as in section 3 step 3, then verify against the reverted `main`:

```bash
git checkout main && git pull
scripts/argocd_staging_verify.sh | tee tmp/phase7-rollback-verify.txt   # Verify OK at the previous tag and hash
```

Expected: a new history ID whose revision is the revert's merge commit, the newest pod running the
previous tag with the previous `SHORT_COMMIT_HASH`, `/health` 200, staging TFC run 0 changes,
production run 1 to change (handle per section 2). Record it with `--kind rollback`. Then move
staging forward again with the next bump cycle (or revert the revert through the same flow);
do not leave staging behind the newest image for longer than the next cycle.

If the revert must land faster than the poll (an actual incident rather than this test),
`argocd app get automation-calculator --refresh` after the merge shortens the wait to seconds and
is still not a manual sync. Only if ArgoCD itself cannot sync should `argocd app sync` be used, and
then the cycle is logged with manual intervention `yes`.

## 5. Recording a cycle

After `scripts/argocd_staging_verify.sh` passes, append the cycle to the log and commit it:

```bash
# --kind is bump (default) or rollback; --manual-intervention is yes if anything in section 6.3 happened
scripts/argocd_soak_log.py add \
  --date <merge date, YYYY-MM-DD> \
  --kind bump \
  --tag <image.tag deployed> \
  --pr <PR number> \
  --history-id <ID from argocd app history> \
  --time-to-sync <merge to sync finished, e.g. 4m> \
  --manual-intervention no \
  --notes "TFC staging 0 changes; production confirmed"
scripts/argocd_soak_log.py status                # prints the gate, rewrites the Gate section
git add docs/argocd-staging-soak-log.md && git commit -m "Soak log: cycle <n> (<tag>)"
```

`add` refuses a history ID that is already in the table. Commit the log through a PR like
everything else (it touches nothing any workspace watches, so no TFC run is queued).

## 6. When a sync does not go to plan

### 6.1 Triage, read-only first

```bash
argocd app get automation-calculator                                 # which resource is OutOfSync / Degraded, and the operation message
argocd app diff automation-calculator                                # what ArgoCD wants to change (exit 1 = there is a diff)
kubectl -n automation-calculator describe deploy automation-calculator
kubectl -n automation-calculator get pods -o wide
kubectl -n automation-calculator describe pod <newest pod>           # image pull errors, probe failures
kubectl -n automation-calculator logs <newest pod> --tail=200
kubectl -n automation-calculator get events --sort-by=.lastTimestamp | tail -n 30
kubectl -n argocd logs deploy/argocd-repo-server --tail=100          # render errors (bad values file, chart syntax)
kubectl -n argocd logs statefulset/argocd-application-controller --tail=100
```

What the states usually mean:

| Symptom | Usual cause | Fix |
|---|---|---|
| `OutOfSync` for more than one poll, no operation running | ArgoCD cannot render or apply: `argocd app get` shows a `ComparisonError` or the operation message says so; repo-server log has the detail | Fix in git (a revert, or a chart fix PR). Never edit the live object. |
| `Syncing` stuck, then `Failed` operation | Apply rejected (immutable selector, project permission) | The message names the resource; the fix is in git or the Terraform-managed AppProject/Application (`terraform/modules/kubernetes/argocd`). |
| Synced but `Progressing` for over 10 minutes, then `Degraded` | New pod never becomes Ready: image tag missing on Docker Hub (`ImagePullBackOff`), or `/health` failing (database, migration) | `describe pod` and logs say which. Old pod keeps serving (rolling update, `maxUnavailable` 25% of 1 rounds to 0). Revert (section 4). |
| Synced, Healthy, but the site serves the old build | The pod carries the tag but `SHORT_COMMIT_HASH` is stale: the image was tagged from the wrong commit | Not a deploy problem; the verify script fails on the hash on purpose. Fix the image, bump again. |
| Self-heal reverting something every few minutes | Someone edited a live object by hand | Stop editing; the desired state is `main`. The edit counts as manual intervention. |

### 6.2 Rolling back

The rollback is section 4: a revert PR. Prune and self-heal then put the live objects back to
what the reverted `main` renders. `argocd app rollback` stays refused; do not turn automated
sync off to use it, because the Terraform-managed Application would turn it back on at the next
`argocd_apps` apply and the history entry would be a manual one regardless.

### 6.3 What counts as manual intervention

Anything that was not "merge the PR and wait for ArgoCD". In particular: `argocd app sync`,
`argocd app rollback`, `argocd app set`, `argocd app terminate-op`, any `kubectl` verb other than
`get`/`describe`/`logs`/`port-forward` in `automation-calculator` or `argocd`, any `helm` command
against the cluster, a `rollout restart`, a TFC run on the staging workspace that applied
something to make the deploy work. Refreshing (`argocd app get --refresh`), reading and
port-forwarding do not count. Record `--manual-intervention yes` with what was done in the notes;
the gate restarts from the next clean cycle.

### 6.4 Confirming no manual intervention happened

Before recording `no`, check the evidence rather than memory:

```bash
# Every history entry since the baseline was started by the automation, not a user
kubectl -n argocd get application.argoproj.io automation-calculator \
  -o jsonpath='{range .status.history[*]}{.id}{"\t"}{.deployedAt}{"\t"}{.initiatedBy}{"\n"}{end}'   # initiatedBy {"automated":true} on each new ID
# Only ArgoCD and Kubernetes controllers have written the Deployment spec
kubectl -n automation-calculator get deploy automation-calculator -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\t"}{.time}{"\n"}{end}'   # argocd-controller (Apply/Update), kube-controller-manager; no kubectl-edit, kubectl-patch, helm
helm -n automation-calculator list                                 # still empty
```

and in the TFC UI, every `ac_app_staging_cluster_addons_layer` run in the window planned 0
changes (or was a change unrelated to the app, noted in the log).

## 7. The soak gate

From the plan: **at least three bump cycles and at least one week without manual intervention**
before Phase 8. `scripts/argocd_soak_log.py status` applies it as:

1. at least 3 `bump` cycles with manual intervention `no`, counted after the most recent cycle
   with `yes` (if any);
2. at least 7 days between the first of those clean cycles and the evaluation date.

A `yes` restarts both counts. The rollback test (section 4) is reported in the output but is not
one of the three; do it anyway, Phase 8 inherits this rollback path. The Gate section of the log
holds the latest result with its date; re-run `status` on the day Phase 8 starts so the date in
the file is current.

## 8. Done when

- `docs/argocd-staging-soak-log.md` lists at least three bump cycles and one rollback cycle,
  each with a verify transcript in `tmp/` at the time and `Verify OK`.
- Every staging TFC run triggered by those merges planned 0 changes.
- `scripts/argocd_soak_log.py status` prints `PASS` and the committed Gate section says so.
- `helm -n automation-calculator list` is still empty and the Application is still on
  `Automated (Prune), Self Heal`, Synced, Healthy.
- Phase 8 (`argocd_enabled = true` on production, then the Phase 6 runbook against the
  production workspace) can start.
