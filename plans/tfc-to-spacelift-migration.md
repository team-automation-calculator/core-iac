# Terraform Cloud to Spacelift migration: investigation and plan

Status: **proposal** (draft PR). Nothing below is implemented. This document records the costs and
benefits of moving this repo's Terraform orchestration from HCP Terraform (Terraform Cloud, "TFC")
to Spacelift, and lays out an expand-and-contract migration broken into one PR per step with time
and reliability estimates.

Prices and feature tiers were checked on 2026-11-04 against the vendors' public pages (sources at
the end). Anything marked **verify** could not be confirmed from a public page and must be checked
in the vendor UI or by running `scripts/tfc_workspace_inventory.py` before the go/no-go decision.

## Summary and recommendation

- **Money is not the reason to move.** This estate is small (see "Current TFC footprint"). On the
  current HCP Terraform free tier it costs $0 as long as it stays under 500 managed resources. Even
  if it crosses that line, Essentials pay-as-you-go at $0.10 per resource per month is tens of
  dollars a month. Spacelift Free is also $0 but caps the account at **2 users and 1 public
  worker**; the first paid tier starts at **$399/month** (10 users, 2 workers). If more than two
  humans need the Spacelift UI, Spacelift is the more expensive option by roughly $4,800 a year.
- **The real benefits are structural**: first-class stack dependencies with output passing (replaces
  the run trigger plus `tfe_outputs` pair), native OpenTofu support as a hedge against the Terraform
  BSL/IBM pricing trajectory, OIDC-based AWS credentials instead of static access keys in workspace
  variables, and a Terraform provider that can manage the whole Spacelift account from this repo.
  HCP Terraform offers OIDC dynamic credentials too; what it does not offer is the OpenTofu hedge
  and the user-unlimited free tier is the thing holding it in place.
- **What it does not fix**: the stale-plan problem for Helm and Kubernetes resources (the EKS token
  is fetched at plan time in both products) and the "production needs a human to confirm" gate.
  Those are addressed by the ArgoCD plan (`docs/argocd-migration-plan.md`), not by changing
  orchestrator.
- **Recommendation**: do Phase 0 (inventory, free-tier Spacelift account, and the development
  environment on Spacelift in plan-only mode). That is about one working day and touches nothing
  that serves traffic. Decide at the go/no-go gate using the real resource count, the number of
  humans who need UI access, and whether the development stack ran cleanly. If the answer is
  "stay", the only lasting change is the inventory script and an OIDC provider that can be removed.

Effort if the full migration goes ahead: **roughly 24 to 36 engineer-hours over 3 to 5 calendar
weeks**, the calendar time being soak periods between environments. Reliability risk is low for
development and staging and **medium for the production cutover** (a state import plus a one-time
forced apply on a workspace that owns the production EKS cluster), mitigated by running TFC and
Spacelift side by side until the Spacelift plan is empty.

## Current TFC footprint

Organization `team-automation-calculator`, VCS-driven workspaces created by the `tf_cloud_workspaces`
module from `terraform/env/<env>/tf_cloud`. Eight workspaces:

| Workspace (backend name) | Config directory | Auto-apply | Depends on | Notes |
|---|---|---|---|---|
| `ac_app_base_cluster_layer_development` | `env/development/aws/us-west-1/base-cluster-layer` | yes | | cluster intentionally unprovisioned |
| `ac_app_development_cluster_addons_layer` | `env/development/aws/us-west-1/cluster-addons-layer` | yes | base (run trigger + `tfe_outputs`) | |
| `ac_app_base_cluster_layer_staging` | `env/staging/aws/us-west-1/base-cluster-layer` | yes | | VPC, EKS, IAM, SSO permission sets |
| `ac_app_staging_cluster_addons_layer` | `env/staging/aws/us-west-1/cluster-addons-layer` | yes | base | Helm add-ons, RDS, Rails app release |
| `ac_app_base_cluster_layer_production` | `env/production/aws/us-west-1/base-cluster-layer` | no | | |
| `ac_app_production_cluster_addons_layer` | `env/production/aws/us-west-1/cluster-addons-layer` | no | base | |
| `ac_app_route53_domain_production` | `env/production/aws/us-east-1/route53-domains` | no | | registered domains |
| `ac_app_production_github_org` | `env/production/github/org` | no | | holds sensitive `GITHUB_TOKEN` env var |

Plus the three `tf_cloud` bootstrap workspaces themselves (one per environment) that exist only to
create the above, and a variable set carrying `TFE_TOKEN` and `TF_VAR_GITHUB_TOKEN`.

TFC features in use, each of which needs a Spacelift equivalent:

| TFC feature | Where | Spacelift equivalent |
|---|---|---|
| VCS-driven runs, `working_directory` | every workspace | stack `project_root` |
| `trigger_prefixes` (module directories queue runs) | module variables `*_module_directories` | stack `additional_project_globs` |
| `auto_apply` true for dev/staging, false for prod | tfvars | stack `autodeploy` |
| `tfe_run_trigger` base to addons | module | stack dependency (referenceless, or with references) |
| `tfe_workspace_settings.remote_state_consumer_ids` + `data "tfe_outputs"` | addons `main.tf`, `provider.tf` (6 outputs read) | dependency references injected as `TF_VAR_*`, or `terraform_remote_state` with external state access |
| Pinned `terraform_version` 1.17 | tfvars | stack `terraform_version`, workflow tool `TERRAFORM_FOSS` (**verify** 1.17 is in Spacelift's picker; see risks) |
| Static AWS access keys as workspace env vars | TFC UI, per workspace | AWS OIDC integration, no static keys |
| Sensitive workspace variables (`github_oauth_app_secret`, `google_oauth_app_secret`, `GITHUB_TOKEN`) | TFC UI | Spacelift context or stack environment variables (write-only) |
| `tfe_oauth_client` built on a GitHub PAT | `tf_cloud` configs | Spacelift GitHub App (no PAT) |
| TFC-managed state | all | Spacelift-managed state, imported at stack creation |

Two housekeeping facts surfaced while reading the code and matter for the migration:

- **Workspace-name drift.** The backend blocks name the base-layer workspaces
  `ac_app_base_cluster_layer_<env>` and the domains workspace `ac_app_route53_domain_production`,
  while the module would create `ac_app_<env>_base_cluster_layer` and
  `ac_app_production_route53_domains`. The live workspaces evidently predate the module naming. The
  inventory script shows which names actually exist; the Spacelift stacks should get the module's
  (consistent) names and the drift disappears with the TFC workspaces.
- **`tfe_outputs` runs with the TFC run's own token** inside TFC. On Spacelift there is no
  implicit `TFE_TOKEN`, so the addons configs cannot keep that data source during the overlap
  period without one being injected. The plan removes it behind a variable before any addons stack
  moves (PR 4).

**Resource count.** The TFC API's `resource-count` per workspace is the number that drives both
vendors' pricing. It was not reachable from this session (no `TFE_TOKEN` in the environment), so
run:

```bash
TFE_TOKEN=... python3 scripts/tfc_workspace_inventory.py
```

A code-based estimate: 64 `resource` blocks and 26 `module` calls in this repo (networking 13,
cluster-addons 15, main_rails_app 8, ci-iam-role 6, sso-infra-eng 6, route53-domain 2, plus the
IRSA role modules), with `terraform-aws-modules/eks` (managed node group, access entries, KMS,
logging, security groups) expanding to roughly 40 to 60 resources on its own. Staging and
production each land somewhere around 120 to 180 resources; development, route53 and the GitHub
org are small.
**Expect 250 to 400 in total**, under the 500-resource free cap but not by a large margin. The
ArgoCD plan removes the Rails Helm release from Terraform, which lowers the count slightly.

## Pricing (checked 2026-11-04)

### HCP Terraform (current)

| Tier | Price | Managed resources | Concurrent runs | Users |
|---|---|---|---|---|
| Free | $0 | up to 500 | 1 | unlimited |
| Essentials | $0.10 per resource per month ($0.00013/hour), billed on peak hourly count | unlimited | 3 | unlimited |
| Standard | $0.47 per resource per month | unlimited | 10 | unlimited |
| Premium | $0.99 per resource per month | unlimited | 200 | unlimited |

The legacy free plan was retired on 2026-03-31; legacy free organizations were moved to the new
500-resource free tier. **Verify** in the TFC organization settings which plan
`team-automation-calculator` is on today and whether any trial credit is in play.

### Spacelift

| Tier | Price | Users | Workers (concurrency) | Added in this tier |
|---|---|---|---|---|
| Free | $0 | 2 | 1 public | VCS, cloud integrations (AWS OIDC and AssumeRole), stack dependencies, Terraform provider, resource view, 1 API key |
| Starter | from $399/month, annual | 10 | 2 public | policy engine, private module registry, webhooks, notifications, custom tasks |
| Business | quote | unlimited | public or private | drift detection, blueprints, scheduling, private provider registry |
| Enterprise | quote | | from 5, public or private | SAML SSO, audit trail, OIDC API keys |

Spacelift does not publish a per-worker or per-run rate; Starter and above are annual contracts.

### Cost scenarios for this estate

| Scenario | TFC per year | Spacelift per year |
|---|---|---|
| ≤ 500 resources, ≤ 2 humans in the UI | $0 | $0 |
| ≤ 500 resources, 3 to 10 humans in the UI | $0 | $4,788 (Starter) |
| 600 resources, ≤ 2 humans | ~$720 (Essentials) | $0 |
| 600 resources, 3 to 10 humans | ~$720 | $4,788 |
| 1,000 resources, needs policies or drift detection | ~$5,640 (Standard) | $4,788 (Starter) to quote (Business) |

The break-even is almost entirely about the **2-user cap on Spacelift Free**. Today this repo's
Terraform is driven by one infra engineer and a CI machine user (the machine user does not need a
Spacelift seat: the GitHub App replaces its VCS role, and image-bump PRs do not touch Spacelift).
If that stays true, both are free and the comparison is purely on features. The inventory script
plus a count of people who actually log into TFC settles it.

## Benefits of moving

- **Stack dependencies with output references.** Base to addons becomes a declared dependency that
  carries `vpc_id`, `eks_cluster_name`, etc. as inputs, triggers only when a referenced output
  changes, and shows the graph in the UI. Today that is a run trigger plus a provider data source
  that needs a TFC token.
- **No static AWS keys anywhere.** The AWS OIDC integration issues a per-run token; the trust policy
  pins the subject to `space:<space>:stack:<stack>:run_type:TRACKED:scope:write`, so a plan-only
  (proposed) run cannot assume the write role. This fits the repo's "no long-lived access keys"
  rule, which today has TFC as its single documented exception (`docs/aws-sso-auth.md`).
- **OpenTofu optionality.** `terraform_workflow_tool = "OPEN_TOFU"` is a per-stack switch. This
  does not require switching, but removes the dependence on IBM/HashiCorp's pricing for the runtime
  and the control plane at the same time.
- **Account-as-code.** The `spacelift-io/spacelift` provider manages stacks, contexts, integrations,
  dependencies and policies from this repo, in the same pattern as the existing `tf_cloud` bootstrap
  but with fewer out-of-band objects (no OAuth client, no variable set).
- **Proposed runs on pull requests** post a plan as a GitHub check per stack, which TFC also does
  but which today is not wired up (CI only runs `fmt` and `validate`).
- **Exit path**: `terraform_external_state_access` plus `terraform state pull` gives the state back
  at any time, so lock-in is no worse than TFC.

## Costs and risks of moving

- **Engineering time**: 24 to 36 hours (breakdown below), most of it careful, low-parallelism work
  on production.
- **A one-time production state import and forced apply.** Spacelift only exposes outputs produced
  by an apply phase, so after importing state each stack needs one tracked run with a (no-op) apply
  before dependents can read its outputs. The run must be inspected for an empty plan before
  confirming. This is the single riskiest moment in the plan.
- **Two orchestrators for a while.** During expand, both TFC and Spacelift can plan the same
  directory; only one may apply. The plan uses the AWS trust policy (read-only role for Spacelift
  until cutover) as a hard guard, not just a UI setting.
- **Terraform version availability**: Spacelift's `TERRAFORM_FOSS` picker "may lag a bit behind
  the latest available Terraform release". If 1.17 is not offered, choose the highest offered 1.x;
  state written by 1.17 is readable by earlier 1.x under the v1 compatibility promise (the
  dependency-upgrade plan relies on the same fact). **Verify** in Phase 0.
- **Spacelift Free has no policy engine**: the "production needs a human" gate is just
  `autodeploy = false` and the confirm button, which is exactly what TFC provides today. Approval
  policies need Starter.
- **Autoretry of proposed runs** needs a private worker pool (Business). Not used today, no loss.
- **Secrets must be re-entered by hand.** TFC never returns sensitive variable values. The OAuth
  app secrets and the GitHub org owner token come from the password manager, not from TFC. The
  `liftoff` tool has a `mutate` step that can capture them by temporarily flipping them
  non-sensitive; the plan avoids that because there are only four values.
- **Sensitive outputs across dependencies** need the stack setting "transfer sensitive outputs"
  enabled. None of the six outputs read today are sensitive.
- **Docs and muscle memory**: README, CLAUDE.md, `docs/aws-sso-auth.md`, `docs/github-ci-user.md`,
  the ArgoCD and dependency-upgrade plans all name TFC. The contract phase updates them.

## Migration tooling considered

**`liftoff`** (spacelift-solutions/liftoff) discovers a TFC estate into a local store, renders an
OpenTofu module for a Spacelift admin stack, and moves secrets, tfvars and state in a finalize
step. It is the vendor's current kit (the older `spacemk` is superseded). For eight workspaces
whose definitions already live in a Terraform module in this repo, hand-writing the
`spacelift_stack` resources is less work than reviewing generated code, keeps the same
`env/<env>/<orchestrator>` layout the repo already uses, and avoids granting a third-party binary
an admin TFC user token. Use `liftoff discover` and `liftoff audit` read-only if a second opinion on
the inventory is wanted; do not use `publish` or `mutate`.

## Target layout

```
terraform/
  modules/
    spacelift/stacks/            # replaces tf_cloud/tf_cloud_workspaces (one PR, additive)
  env/
    <env>/
      spacelift/                 # replaces <env>/tf_cloud (stack definitions, dependencies,
                                 #   AWS integration attachments, contexts)
      aws/us-west-1/...          # unchanged directories; backend "remote" block removed at cutover
```

Design decisions:

- **Spacelift-managed state**, imported with `import_state_file` at stack creation. An S3 backend
  was considered and rejected for the overlap period: TFC remote runs refuse a non-TFC backend, so
  S3 could not be shared by both orchestrators anyway, and it would add a bucket, a lock table and
  an IAM policy to maintain for no gain.
- **Dependency references, not `terraform_remote_state`**, for base to addons. References give the
  "trigger only when an output changed" behaviour, need no state-access role bindings, and the
  values arrive as plain `TF_VAR_*`. The addons config gets an explicit `base_layer` object
  variable (PR 4). The list output `private_eks_subnet_ids` arrives as a JSON string, which
  Terraform parses for a `list(string)` variable set through `TF_VAR_`.
- **One AWS OIDC provider per account, two roles per environment**: the existing
  `ac_ci_terraform_<env>` (write) and `ac_ci_terraform_<env>_read_only` roles gain a trust
  statement for the Spacelift OIDC provider, with the `sub` condition restricting the write role to
  `run_type:TRACKED:scope:write` on that environment's stacks. The `ci-iam-role` module already
  takes `trusted_principal_arns` and `read_only_trusted_principal_arns`; it grows
  `spacelift_oidc_provider_arn`, `spacelift_oidc_read_subjects` and `spacelift_oidc_write_subjects`
  inputs. No new roles.
- **Spacelift account bootstrap** mirrors the TFC one: the first apply of each
  `env/<env>/spacelift` directory runs locally with a Spacelift API key, then an administrative
  stack with a stack role attachment tracks the directory. The API key lives only in the operator's
  shell for that first run.
- **Spaces**: one space per environment (`development`, `staging`, `production`), which also scopes
  the OIDC subject patterns and the eventual role bindings.
- **Stack names** use the module's consistent form `ac_app_<env>_<layer>`.
- **GitHub**: install the Spacelift GitHub App on `team-automation-calculator` with access to
  `core-iac` only. The machine user plays no role.

## Expand and contract, step by step

The sequence is development first (nothing provisioned, so the whole flow is exercised at no
risk), then staging, then production's four stacks, then teardown. Every step has a rollback that
is "TFC still owns it; delete the Spacelift stack". Not until PR 10 is anything removed from TFC.

Legend for the estimates: **time** is hands-on engineer time including review and manual UI steps;
**calendar** is the soak before the next PR; **risk** is to running infrastructure, not to the
branch.

### Phase 0: expand the ground (no production change)

**PR 1. This document, inventory script, go/no-go checklist.** Time 1 h. Risk none.
Manual: run `scripts/tfc_workspace_inventory.py` and paste the table into the PR. Count humans who
log into TFC. Record the TFC plan from organization settings.

**Manual 1. Create the Spacelift account** (Free tier, sign in with GitHub so the Marketplace app
is the default integration), install the GitHub App on the org with access to `core-iac`, create
one API key for bootstrap. Time 1 h. Risk none. Record the account's OIDC issuer and audience
(`iss`, `aud` from the account's OIDC settings) in the PR 2 tfvars.

**PR 2. AWS OIDC provider and trust statements (base-cluster-layer, applied through TFC).**
Adds `aws_iam_openid_connect_provider` for the Spacelift issuer (one per AWS account; put it in the
`ci-iam-role` module behind a `spacelift_oidc_issuer` variable with a count) and extends both CI
roles' trust policies with `AssumeRoleWithWebIdentity` statements conditioned on the `sub`
patterns. Development first, then staging, then production, each a tfvars line in the same PR
applied via the existing TFC workspaces. The read-only role trusts `scope:read` and `scope:write`
runs of the environment's stacks (plans); the write role trusts only `run_type:TRACKED` and
`scope:write`, and **in this PR the write trust is left empty for staging and production**
(`spacelift_oidc_write_subjects = []`). Time 3 h. Calendar: production apply is a manual confirm.
Risk low: additive IAM only; a wrong `sub` pattern denies rather than grants.

**PR 3. `modules/spacelift/stacks` module and `env/development/spacelift`.** New module with
`spacelift_space`, `spacelift_stack` (base and addons), `spacelift_stack_dependency`,
`spacelift_stack_dependency_reference` for the six outputs, `spacelift_aws_integration` (OIDC)
attachments read-only, `additional_project_globs` mirroring today's `*_module_directories`,
`autodeploy = false` for every stack until cutover, `protect_from_deletion = true`,
`terraform_version` from the same tfvars value TFC uses, `import_state_file` pointing at a
gitignored `tmp/state/<stack>.tfstate`. CI: `fmt` and `validate` jobs for the module and the env
directory, matching the `tf_cloud` ones. Time 5 h. Risk none to infrastructure.
Manual: `terraform state pull` from each development TFC workspace into `tmp/state/`, local apply
with `SPACELIFT_API_KEY_*` set, then one proposed run per stack. Expect the development base stack
to plan the same "would create the cluster" diff TFC shows, and the addons stack to fail with
"missing inputs" until base has an apply phase. Because development has nothing to lose, run base
with **force apply** (no-op) to publish outputs, then confirm addons also plans the same as TFC.
This is the full dress rehearsal.

**Go/no-go gate.** Inputs: resource count vs 500, humans vs 2, Terraform 1.17 availability on
Spacelift, and whether the development stacks reproduced TFC's plans. If no-go: close the branch,
optionally revert PR 2 (the OIDC provider is harmless to keep). Cost of a no-go: about one day.

### Phase 1: expand to staging

**PR 4. Decouple addons from `tfe_outputs` (all three environments, applied through TFC).**
Add `variable "use_tfe_outputs"` (default `true`) and six scalar variables mirroring the base
layer outputs read today (`base_environment_name`, `base_eks_cluster_name`,
`base_ci_read_only_kubernetes_group`, `base_eks_cluster_oidc_provider_arn`,
`base_private_eks_subnet_ids`, `base_vpc_id`, all defaulting to `null`) to each addons env
config. Give the `tfe_outputs` data source `count = var.use_tfe_outputs ? 1 : 0` and route every
reference through a `local.base` object that takes the variables when `use_tfe_outputs` is false
and the data source otherwise. Six scalars rather than one object because a dependency reference
sets one `TF_VAR_*` each and cannot fill a single field of an object. No plan change in TFC. Time
2 h. Risk none (zero-diff plans; the three existing `validate` jobs cover the TFC side). On
Spacelift the stack environment sets `TF_VAR_use_tfe_outputs=false` and the references supply the
rest.

**PR 5. `env/staging/spacelift`: stacks in plan-only mode.** Same shape as development. Manual:
state pull from the two staging TFC workspaces, local bootstrap apply, force-apply the base stack
(expect no-op; inspect that the plan is empty before confirming), proposed run on addons, compare
plans with TFC's latest run. Time 3 h. Calendar: 2 to 3 days of both orchestrators planning the
same merges to catch drift between them. Risk low: the write role does not trust Spacelift yet, so
a mistaken confirm fails at `AssumeRoleWithWebIdentity`.

**PR 6. Staging cutover.** In one PR: (a) tfvars in base-cluster-layer sets the staging
`spacelift_oidc_write_subjects` (applied via TFC, its last staging apply); (b) remove the
`backend "remote"` block from the two staging configs (Spacelift injects its own backend and
refuses a declared one); (c) `autodeploy = true` for the two staging stacks and the AWS integration
attachment gains `write = true`; (d) the TFC module gets `enable_staging = false`-style toggles so
the run trigger and VCS connection are dropped from the staging TFC workspaces (workspaces kept,
VCS disconnected, so nothing in TFC queues on merge). Order of operations inside the PR is in the
PR body: TFC applies (a) first, then the operator runs the final `state pull` into Spacelift via
"import on top of latest" in the State history tab, then merges, then Spacelift applies the
rest. Time 4 h. Calendar: 1 week soak with at least one real change (an image bump via the
existing scripts is ideal: it exercises the Helm release path). Risk **medium-low**: the staging
cluster and RDS are owned by the state being moved; mitigations are the empty-plan check, the TFC
workspace kept intact and lockable, and `terraform state push` back to TFC as the documented
rollback.

### Phase 2: expand to production

**PR 7. `env/production/spacelift`: four stacks in plan-only mode** (base, addons, route53
domains, github org). The `GITHUB_TOKEN` for the org stack and the OAuth app secrets for addons are
entered as write-only stack environment variables by hand from the password manager (do not pull
them from TFC). Same manual sequence as PR 5 for all four; route53 and github org have no
dependencies and import cleanly. Time 3 h. Calendar 2 to 3 days. Risk low (read-only role).

**PR 8. Production cutover.** Same shape as PR 6, with two differences: `autodeploy` stays
`false`, and the operator window is scheduled, with the TFC workspaces locked before the final
state pull so no TFC apply can land in between. The force-apply of base must show an empty plan;
anything else aborts the window and the Spacelift stack is deleted (TFC still owns everything).
Time 4 h including the window. Calendar: 1 week soak with a production image bump through
Spacelift's confirm flow. Risk **medium**: production EKS, RDS, ALB and DNS state moves; the
rollback is the same `state push` to the locked TFC workspace, and the window is chosen when no
deploy is pending.

### Phase 3: contract

**PR 9. Remove TFC from the configs.** Delete the `tfe` provider from the addons configs and lock
files, the `tfe_outputs` toggle (now always the variables), `tf_cloud_organization_name` and
`tfe_base_layer_workspace_name` variables and tfvars lines. Time 2 h. Risk none (Spacelift plans
show no change).

**PR 10. Delete the TFC workspaces.** Set the workspace counts to zero in the `tf_cloud` module
(or delete the `tf_cloud` directories and let the operator destroy the bootstrap workspaces by
hand: the oauth client and variable set are the only other objects). Download a final copy of each
workspace's state to the password-manager-adjacent archive first. Then delete the TFC
organization, or leave it empty on the free tier as a cold rollback for a month. Time 2 h. Risk
none after the soak; the archived states are the last resort.

**PR 11. CI and docs.** CircleCI: drop the nine `*_tf_cloud_env` and module jobs, keep the
Spacelift ones added in PRs 3, 5, 7. README setup section, CLAUDE.md (layout, backend, required
env vars: `SPACELIFT_API_KEY_ID`/`SECRET` replace `TFE_TOKEN`), `docs/aws-sso-auth.md` ("the one
legitimate access-key holder" paragraph goes away), `docs/github-ci-user.md` (the `TF_VAR_GITHUB_TOKEN`
consumer row and the oauth-client replacement row go away), the two plan docs' TFC references.
Time 2 h. Risk none.

**PR 12 (optional). Remove the static AWS keys from the repo's history of practice.** Rotate and
delete the IAM access keys the TFC workspaces used. These are not Terraform-managed today
(**verify**: the keys' owner user). Time 1 h. Risk none once TFC has no workspaces.

### Estimate summary

| Step | Hands-on | Calendar after | Infra risk |
|---|---|---|---|
| PR 1 plan + inventory | 1 h | | none |
| Manual 1 Spacelift account | 1 h | | none |
| PR 2 OIDC trust (3 envs) | 3 h | prod confirm | low |
| PR 3 dev stacks + rehearsal | 5 h | gate | none |
| PR 4 `tfe_outputs` toggle | 2 h | | none |
| PR 5 staging plan-only | 3 h | 2 to 3 days | low |
| PR 6 staging cutover | 4 h | 1 week | medium-low |
| PR 7 prod plan-only | 3 h | 2 to 3 days | low |
| PR 8 prod cutover | 4 h | 1 week | medium |
| PR 9 remove tfe provider | 2 h | | none |
| PR 10 delete TFC workspaces | 2 h | | none |
| PR 11 CI and docs | 2 h | | none |
| PR 12 rotate TFC's AWS keys | 1 h | | none |
| **Total** | **33 h** | **3 to 5 weeks** | |

Hands-on hours assume one engineer who knows this repo; add roughly 30% for a first Spacelift
encounter (UI, OIDC subject format, dependency semantics). The two medium-risk steps are the only
ones that need a scheduled window.

## Reliability risk register

| Risk | Where | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Both orchestrators apply the same directory | PR 5 to PR 8 | low | high | write role trusts Spacelift only after the env's TFC VCS connection is dropped in the same PR; TFC workspaces locked during the window |
| Force-apply after state import is not a no-op | PR 3, 5, 7 | low | high on prod | inspect plan before confirm; abort and delete stack if non-empty; dev rehearsal first |
| Dependency chain breaks on a failed base run and addons silently does not run | steady state | medium | low | known Spacelift semantics: a retry does not trigger dependents, re-trigger addons by hand; document in CLAUDE.md |
| Terraform 1.17 absent from Spacelift picker | PR 3 | medium | low | pick highest 1.x available; state is forward-readable; or switch dev to OpenTofu as an experiment |
| List output arrives as JSON and the variable type rejects it | PR 4/5 | low | low | caught by the dev rehearsal; fallback is a `jsondecode` on a string variable |
| Stale EKS token in a plan waiting for confirm (production) | PR 8 onward | same as today | medium | unchanged from TFC; confirm promptly; ArgoCD plan removes the Helm release from Terraform |
| Spacelift public worker lacks a tool a run needs | PR 3 | low | low | the runner image ships terraform, aws cli, kubectl is not needed (providers only); custom runner image is a stack setting |
| Secrets mistyped when re-entered | PR 7 | low | medium | proposed run on the github org stack validates the owner token; addons secrets only affect the Helm release values |
| 2-user cap bites later | steady state | depends | cost | decided at the gate with a head count; Starter is the fallback |

## What stays the same

- The layered apply order (base, then addons) and the per-environment directories.
- `terraform fmt` and `validate` in CircleCI, with the Spacelift env directories replacing the
  `tf_cloud` ones.
- Human AWS access via IAM Identity Center; local plans with `AWS_PROFILE=ac-ci-<env>` keep
  working during and after the migration. Local plans against Spacelift-managed state need
  `terraform login spacelift.io` and external state access enabled on the stack, which the plan
  turns on for the read-only persona in PR 9.
- The image-bump scripts and the deploy-image skill: they edit tfvars and open PRs; the
  orchestrator that reacts is the only thing that changes.

## Open questions for the gate

1. Exact resource count per workspace (inventory script) and the TFC plan the org is on.
2. How many humans need Spacelift UI access in the next year.
3. Is Terraform 1.17 selectable on Spacelift today, and if not, which 1.x is.
4. Whether the ArgoCD migration should land first: it shrinks the addons stacks and removes the
   Helm release from the production cutover's blast radius. Doing ArgoCD first is the lower-risk
   ordering; doing Spacelift first means the ArgoCD per-env `state rm` steps happen in Spacelift
   instead of TFC, which is the same operation.

## Sources

- Spacelift pricing: <https://spacelift.io/pricing>
- HCP Terraform pricing: <https://www.hashicorp.com/en/pricing> and plan limits at
  <https://developer.hashicorp.com/terraform/cloud-docs/overview>
- HCP Terraform legacy free plan retirement (third-party summary):
  <https://scalr.com/learning-center/hcp-terraform-free-tier-is-being-discontinued-what-you-need-to-know>
- Spacelift stack dependencies: <https://docs.spacelift.io/concepts/stack/stack-dependencies>
- Spacelift stack settings (project root, project globs, autodeploy, worker pool):
  <https://docs.spacelift.io/concepts/stack/stack-settings>
- Spacelift AWS OIDC integration: <https://docs.spacelift.io/integrations/cloud-providers/oidc/aws-oidc>
- Spacelift AWS cloud integration (AssumeRole alternative):
  <https://docs.spacelift.io/integrations/cloud-providers/aws>
- Spacelift state management (import at creation, backend injection):
  <https://docs.spacelift.io/vendors/terraform/state-management>
- Spacelift external state access: <https://docs.spacelift.io/vendors/terraform/external-state-access>
- Spacelift Terraform version management: <https://docs.spacelift.io/vendors/terraform/version-management>
- Spacelift GitHub integration: <https://docs.spacelift.io/integrations/source-control/github>
- `spacelift_stack` resource arguments:
  <https://github.com/spacelift-io/terraform-provider-spacelift/blob/main/docs/resources/stack.md>
- Spacelift migration page and `liftoff`: <https://docs.spacelift.io/product/migrating-to-spacelift>,
  <https://github.com/spacelift-solutions/liftoff>
