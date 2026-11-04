# arm64 (Graviton) worker node migration plan

Status: **proposal** (draft PR). Nothing below is implemented yet. The change itself is two tfvars
lines per environment; the work is in getting the application image published for arm64 first and
keeping local development, CI and the clusters on the same architecture afterwards.

Facts below were checked on 2026-11-04 against the live staging and production clusters (via the
SSO read-only kubectl contexts), Docker Hub and the public registries, the AWS price list for
us-west-1, and the `automation-calculator` application repo at `main` (547f98d).

## Why

- **Cost.** `t4g.medium` is 19% cheaper than the `t3.medium` both clusters run on, with the same
  2 vCPU, 4 GiB, 20% baseline and 24 CPU credits per hour, so there is no burst-credit regression.
  AWS's own claim for T4g over T3 is "up to 40% better price performance" for Linux workloads.
- **Alignment with local development.** Everyone developing on Apple Silicon already runs the app
  as arm64: `./go start` builds `Dockerfile.development` natively on the host, and the Gemfile.lock
  already resolves `aarch64-linux` native gems. Today that means local dev runs an architecture
  production has never executed. Moving the clusters to arm64 closes that gap instead of widening
  it.
- **The hard part is already done.** The app's `./go build --multi-platform` and
  `./go push --multi-platform` (app PR #195, 2026-05-08) build `linux/amd64,linux/arm64` with
  buildx, and the base image `automation-calculator-base:0.11.0` is already published for both.
  Only the CI job still produces a single-arch image.
- **The database already moved.** RDS runs `db.t4g.micro` (Graviton) in both environments. The
  nodes are the last x86 compute in the stack.

## Scope

In scope: the EKS managed node group AMI type and instance type in staging and production, the
app's CircleCI job (so published images carry an arm64 manifest and tests run on arm64), and the
tfvars for the unprovisioned development environment so it does not drift from the others.

Out of scope: EKS Auto Mode or Karpenter (one node per cluster does not justify them), Spot
capacity, Bottlerocket, resizing beyond `medium`, and the RDS instance class (already Graviton).

## Current state

| Component | Where | Value (2026-11-04) | arm64 ready? |
|---|---|---|---|
| Node group AMI | `env/<env>/aws/us-west-1/base-cluster-layer/terraform.tfvars` `ami_type` | `AL2023_x86_64_STANDARD` (release 1.36.5-20261023) | n/a |
| Node instance type | not set per env; module default in `modules/aws/base-cluster-layer/variables.tf` | `["t3.medium"]`, 1 node, `max_size = 2` | n/a |
| App image | `automationcalculationsci/automation-calculator:0.9.6-987` (running), `:latest` | single manifest, `linux/amd64` only | **No** (CI builds without `--multi-platform`) |
| App base image | `automationcalculationsci/automation-calculator-base:0.11.0` | `linux/amd64, linux/arm64` | Yes |
| App runtime base | `ruby:4.0.9-slim-trixie` | 7 platforms incl. arm64 | Yes |
| Gemfile.lock | `PLATFORMS: aarch64-linux, ruby, x86_64-linux` | precompiled `aarch64-linux` for nokogiri, pg, google-protobuf, sass-embedded | Yes (bcrypt, ffi, puma, json, nio4r etc. compile from source on either arch) |
| Node.js in image | nodesource `setup_26.x` | publishes arm64 debs | Yes |
| aws-load-balancer-controller | `public.ecr.aws/eks/aws-load-balancer-controller:v3.6.1` | `linux/amd64, linux/arm64` | Yes |
| external-dns | `registry.k8s.io/external-dns/external-dns:v0.21.0` (prod), `v0.23.0` (staging) | `linux/amd64, linux/arm, linux/arm64` | Yes |
| metrics-server | `registry.k8s.io/metrics-server/metrics-server:v0.9.0` | amd64, arm, arm64, ppc64le, s390x | Yes |
| vpc-cni, network-policy-agent, CoreDNS, kube-proxy | EKS default add-ons from `602401143452.dkr.ecr.us-west-1.amazonaws.com` | EKS-built, multi-arch | Yes |
| Helm chart scheduling | `helm/automation-calculator/values.yaml` | no `nodeSelector`, `affinity` or `tolerations` set | Nothing to change |
| Local dev | `docker-compose.dev.yml` builds `Dockerfile.development` on the host | arm64 on Apple Silicon, amd64 on Intel/Linux | Already native |
| CI | `.circleci/config.yml` in the app repo: Docker executor `cimg/ruby:4.0-node` + `setup_remote_docker` | amd64 build, amd64 tests, amd64-only push | **No** |
| Local Docker | Docker 29.9.2 on an arm64 Mac | buildx available | Yes |

Every image the clusters run has an arm64 manifest except the application's own. That is the
one blocker, and it is a CI change, not an application change.

## Cost

AWS on-demand price list, us-west-1, Linux, shared tenancy, 730 h/month:

| Instance | Arch | vCPU / RAM | Baseline / credits per h | $/h | $/month | vs t3.medium |
|---|---|---|---|---|---|---|
| t3.medium (current) | amd64 | 2 / 4 GiB | 20% / 24 | 0.0496 | 36.21 | |
| t3a.medium | amd64 (AMD) | 2 / 4 GiB | 20% / 24 | 0.0446 | 32.56 | -10% |
| **t4g.medium (proposed)** | arm64 | 2 / 4 GiB | 20% / 24 | 0.0400 | 29.20 | **-19%** |
| t3.large | amd64 | 2 / 8 GiB | 30% / 36 | 0.0992 | 72.42 | |
| t4g.large | arm64 | 2 / 8 GiB | 30% / 36 | 0.0800 | 58.40 | -19% vs t3.large |

Savings with one node per cluster: $7.01 per cluster per month, $14.02 per month for staging plus
production, about $168 per year. If a cluster ever needs `large` for headroom, the arm64 price gap
widens to $14 per node per month.

For perspective, each EKS control plane costs $0.10 per hour (~$73 per month) regardless of node
type, so the node change trims the per-environment bill by roughly 5%. The saving is real but
small; the alignment argument carries at least as much weight.

CI cost moves in the other direction unless the executor is chosen carefully (see Decisions):
CircleCI charges 13 credits per minute for an Arm Docker medium executor against 10 for x86
Docker medium, but an Arm Linux VM (machine) medium is 10 credits per minute, the same as x86.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Target instance | `t4g.medium` | Same shape as today's `t3.medium` (2 vCPU, 4 GiB, 20% baseline, 24 credits/h), cheapest Graviton option that fits, and `t4g` is current-generation in us-west-1. Keep `medium`; the app requests 250m / 512Mi and limits 750m / 2Gi, so `small` (2 GiB) is too tight once add-ons are counted. |
| AMI type | `AL2023_ARM_64_STANDARD` | The arm64 twin of today's `AL2023_x86_64_STANDARD`; same AL2023 nodeadm bootstrap, so `use_custom_launch_template = false` stays. |
| One node group, replaced in place, not a second arm64 group alongside | Change `ami_type` and `instance_types` on the existing `primary` group | Both attributes are `ForceNew` on `aws_eks_node_group`. The module (21.29.0) sets `use_name_prefix = true` (the live name is `primary-20260506...`) and `create_before_destroy = true`, so Terraform creates the arm64 group first and deletes the x86 group after. A "run both" migration is for clusters where some workloads cannot move; here every image is multi-arch and there is one app pod. |
| Image strategy | Multi-arch manifest (`linux/amd64,linux/arm64`) under the same tags, not arm64-only | Keeps the same `app_version` tag working on either node type during the migration and a rollback, keeps `docker-compose.production_http.yml` and Intel hosts working, and the code path already exists (`./go push prod --multi-platform`). Revisit arm64-only once both clusters have run arm64 for a quarter. |
| Where CI runs | CircleCI **machine** executor, `ubuntu-2404:current`, `resource_class: arm.medium` | Tests then execute natively on the architecture production will serve, which is the alignment goal. Arm machine is billed at the same 10 credits/min as the x86 Docker medium the job uses today, and it drops the separate `setup_remote_docker` VM. The amd64 half of the manifest is cross-built under QEMU. The alternative (stay on the x86 Docker executor, add `tonistiigi/binfmt`, emulate arm64) publishes the right image but never runs a test on arm64. |
| Order | App CI first, then a normal `app_version` bump, then staging nodes, then production nodes | A pod scheduled onto an arm64 node with an amd64-only image fails with `exec format error` and CrashLoops. The node switch must not be applied in any environment until the running `app_version` has an arm64 manifest. |
| Development environment | tfvars updated in the staging PR | The dev cluster is intentionally unprovisioned; keep its tfvars equal to staging so a future apply does not create an x86 cluster. |

## Phases

### Phase 0: verify (no changes)

1. Confirm the running tag is amd64-only and the chart has no arch pinning:
   ```bash
   docker manifest inspect automationcalculationsci/automation-calculator:0.9.6-987 | grep -c arm64   # expect 0 today
   grep -n -E 'nodeSelector|affinity|tolerations' helm/automation-calculator/values.yaml           # all empty
   ```
2. Confirm every non-app image in both clusters has arm64 (list from `kubectl get pods -A -o
   jsonpath='{..image}'`, then `docker manifest inspect` each). Done 2026-11-04; see Current state.
3. Confirm `aws ec2 describe-instance-type-offerings --location-type availability-zone
   --filters Name=instance-type,Values=t4g.medium --region us-west-1` lists both AZs the cluster
   subnets use. Checked 2026-11-04: `t4g.medium` and `t4g.large` are offered in `us-west-1a` and
   `us-west-1c`, the same two AZs that offer `t3.medium`. Re-check at apply time.
4. Build the app locally for both platforms once to flush out anything that only breaks under
   buildx: `./go build prod --multi-platform` in the app repo on an arm64 Mac. The arm64 half is
   native and the amd64 half runs under Rosetta/QEMU; expect several minutes.

### Phase 1: app repo, publish multi-arch images (one PR in `automation-calculator`)

Change `.circleci/config.yml`:

```yaml
jobs:
  build_verify_push:
    machine:
      image: ubuntu-2404:current
    resource_class: arm.medium
    environment:
      USER: "circleci"
    working_directory: ~/repo
    steps:
      - checkout
      # (remove setup_remote_docker; the machine executor has a local Docker daemon)
      - run: ./go build ci          # native arm64
      - run: ./go lint ci
      - run: ./go test ci           # RSpec on arm64
      - run: ./go build prod        # proves the production Dockerfile builds (arm64)
      - when:
          condition:
            equal: [main, << pipeline.git.branch >>]
          steps:
            - run: docker run --rm --privileged tonistiigi/binfmt --install amd64
            - run: docker login --username $DOCKER_HUB_USER --password $DOCKER_HUB_PASSWORD
            - run: ./go push prod --multi-platform
```

Notes:

- `./go push prod --multi-platform` runs one `docker buildx build --platform linux/amd64,linux/arm64
  -t <semver> -t latest --push`, so the `./go tag` step is no longer needed (`DockerHub.semver_tag`
  reads the same `SEMVER_*` and `CIRCLE_BUILD_NUM` variables). It rebuilds rather than reusing the
  image tested above; the buildx `docker-container` driver does not share the daemon's image store.
  Acceptable for now; a follow-up could test against the buildx output instead.
- `tonistiigi/binfmt --install amd64` registers the QEMU handler so the amd64 half can build on the
  arm host. Expect the amd64 half to be the slow part: the native gems without an `x86_64-linux`
  precompiled variant (bcrypt, ffi, puma, json, nio4r, websocket-driver, racc, bigdecimal, date,
  io-console) compile under emulation, and `rails assets:precompile` runs under emulation too.
  Budget 2 to 4x today's build time for the publish step only; branch builds are unaffected
  because they never publish.
- If the emulated amd64 build turns out too slow, split publish into two jobs (`arm.medium` builds
  and pushes `linux/arm64`, x86 `medium` + `setup_remote_docker` builds and pushes `linux/amd64`,
  each under a per-arch tag) and a third step merges them with `docker buildx imagetools create`.
  Do not start there; the single-job form is simpler and the time only matters on `main`.
- The tag-format guard in the CI comments still holds: only `main` publishes, and the semver
  `^\d+\.\d+\.\d+-\d+$` tag is what makes core-iac open a bump PR.
- Rubocop runs on `scripts/` too; keep any Ruby changes lint-clean.

Validate: the next `main` build publishes `0.9.6-<N>`;
`docker manifest inspect automationcalculationsci/automation-calculator:0.9.6-<N>` lists both
`linux/amd64` and `linux/arm64`; the automatic core-iac bump PR runs through the usual
staging-then-production deploy on the **x86** nodes first. This proves the amd64 half is
byte-for-byte as good as before (it is the half production keeps running until Phase 2).

### Phase 2: staging nodes (one PR in this repo)

Precondition: the `app_version` deployed in staging has an arm64 manifest (Phase 1 shipped and was
deployed).

Changes:

1. Add a `node_group_instance_types` variable to each env's `base-cluster-layer/variables.tf`
   (default `["t3.medium"]`, matching the module) and pass it through in `main.tf` next to
   `ami_type`. Today the env configs do not expose it, so there is no way to change it per env.
2. `terraform/env/staging/.../base-cluster-layer/terraform.tfvars`:
   ```hcl
   ami_type                 = "AL2023_ARM_64_STANDARD"
   node_group_instance_types = ["t4g.medium"]
   ```
   and the same two lines in `env/development/...` (unprovisioned, kept in step). Run
   `scripts/sort_tfvars.sh` and `terraform fmt -recursive terraform/`.
3. The plan must show exactly one `aws_eks_node_group` replaced (`# forces replacement` on
   `ami_type` and `instance_types`) and nothing else. Any launch-template or IAM change in the plan
   means the module defaults moved and needs a look before apply.

Rollout (what the apply does): EKS creates `primary-<new>` with one `t4g.medium`, waits for it to
join, then deletes `primary-20260506...`. Deleting a managed node group cordons and drains its
node, which evicts the single app pod; it reschedules on the arm64 node, pulls the arm64 layer of
the same tag, and the ALB controller registers the new node in the target group (target type
`instance`, `externalTrafficPolicy: Local`, so only the node running the pod passes health
checks). Expect a short outage: image pull plus the startup probe window (up to 3 minutes). The
add-ons (ALB controller, external-dns, metrics-server) also move; none keep state on the node.

Zero-downtime variant, if wanted for production: before the apply, set `replicaCount: 2` in the
environment's Helm values and add a `PodDisruptionBudget` with `minAvailable: 1` for the app.
`max_size` is already 2, so the second replica fits on the existing node, and the drain then moves
one replica at a time. Revert to 1 replica after. Not worth it for staging.

Validate:
```bash
kubectl --context ac_app_staging-ro get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type
#   expect: arm64  t4g.medium
kubectl --context ac_app_staging-ro get pods -A -o wide        # all Running on the new node
kubectl --context ac_app_staging-ro -n automation-calculator exec deploy/automation-calculator -- uname -m   # aarch64
```
then `./go smoke staging` from the app repo, and check the ALB target group shows one healthy
target. Watch the CloudWatch alarms (`alb_5xx_errors`, `target_5xx_errors`, `alb_latency_p99`,
`unhealthy_hosts`) for the soak.

Soak at least one week. What to watch: p99 latency (`alb_latency_p99` alarm and the ALB metrics),
memory on the node (`kubectl top node` via metrics-server), and anything that only runs on a
schedule (the `entrypoint.sh` migrations run at every pod start, so they are exercised on day one).

### Phase 3: production nodes (one PR in this repo)

Same two tfvars lines in `env/production/...`. Schedule the apply for a low-traffic window or use
the zero-downtime variant above. Validate with the production context and `./go smoke prod`.

### Phase 4: housekeeping (one PR, after both clusters are arm64)

- Change the module default `node_group_instance_types` to `["t4g.medium"]` and the module and
  env `ami_type` defaults to `AL2023_ARM_64_STANDARD`. The env defaults are currently
  `AL2023_x86_64`, which is not a valid EKS `amiType` value at all (valid: `AL2023_x86_64_STANDARD`,
  `AL2023_ARM_64_STANDARD`, ...); it has only ever worked because every tfvars overrides it.
- Update `CLAUDE.md` conventions: AWS region, and now node architecture arm64.
- Decide whether to keep publishing `linux/amd64`. Reasons to keep it: Intel-based developers or
  hosts using `docker-compose.production_http.yml`, and a free rollback path. If it is dropped,
  `./go push prod` goes back to a plain native push on the arm machine and the QEMU step goes away.

## Rollback

- **Nodes:** revert the two tfvars lines and apply. It is the same `create_before_destroy`
  replacement in reverse (new x86 group, drain arm64 group). Because the image tags are multi-arch
  from Phase 1 on, no `app_version` change is needed in either direction.
- **CI:** revert the config change; the next `main` build publishes amd64-only again. Any tag
  already published as multi-arch stays valid for both node types.
- A failed `create_before_destroy` apply (for example `t4g.medium` capacity unavailable in an AZ)
  leaves the old node group in place and the cluster serving; fix and re-apply.

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| App pod CrashLoops with `exec format error` after node switch | Low once Phase 1 is deployed; certain if the order is violated | Phase 2/3 precondition is a `docker manifest inspect` showing arm64 for the deployed `app_version`. Put that check in the PR body. |
| A gem behaves differently on aarch64 (native extension, endianness, `ffi`) | Low: all natives are mainstream and ship aarch64 builds or compile cleanly; Apple Silicon devs have been running the suite on arm64 locally | Phase 1 runs the full RSpec suite on arm64 in CI before anything is published. |
| QEMU-emulated amd64 half of the publish step is slow or flaky | Medium | Only on `main`, so it does not slow PR feedback. Split into native per-arch jobs plus `imagetools create` if it becomes a problem. |
| `t4g.medium` capacity in a us-west-1 AZ | Low | `create_before_destroy` fails safe. `t4g.large` is the fallback type; `instance_types` is a list, so `["t4g.medium", "t4g.large"]` lets EKS pick. |
| Short outage during the node drain | Certain without the PDB variant | Staging accepts it; production either schedules a window or uses `replicaCount: 2` + PDB. |
| Terraform plan replaces more than the node group | Low | Plan review: exactly one `aws_eks_node_group` replace. Do not apply on surprises. |
| CircleCI Arm machine executor unavailable on the account's plan | Low (Arm resource classes are offered on cloud plans) | Fall back to the x86 Docker executor with `setup_remote_docker` + `tonistiigi/binfmt --install arm64`; publishes the right image, loses native arm64 tests. |

## Verification checklist (per env)

- [ ] Deployed `app_version` manifest lists `linux/arm64` before the base-cluster-layer apply
- [ ] Plan shows one node group replacement and nothing else
- [ ] `kubectl get nodes` shows `arm64` / `t4g.medium`, all pods Running, `uname -m` in the app pod is `aarch64`
- [ ] `./go smoke <env>` passes
- [ ] ALB target group: one healthy target; no CloudWatch alarm fired during or after the switch
- [ ] external-dns log shows `All records are already up to date` after its first sync on the new node (it is a controller restart, not a config change, so no TXT ownership churn is expected)

## Follow-ups (not in scope)

- Register vpc-cni, CoreDNS and kube-proxy as EKS-managed add-ons so Terraform versions them (the
  existing note in `docs/dependency-upgrade-plan-2026-q4.md` Phase 4). Live staging runs
  `kube-proxy v1.32.13` on a 1.36 control plane while production runs `v1.35.3`; that drift is
  unrelated to the architecture but was visible in the Phase 0 image inventory.
- The `t4g.small` free trial (750 hours per month until 2026-12-31) is not useful here: 2 GiB is
  too small for the app plus add-ons, and the trial does not apply to `medium`.

## Sources

- AWS EC2 on-demand price list, US West (N. California), Linux (`b0.p.awsstatic.com` price map), 2026-11-04
- AWS T4 instance page: "up to 40% better price performance over T3", t4g specs and credit rates
- EKS API reference, `Nodegroup.amiType` valid values
- `terraform-provider-aws` `internal/service/eks/node_group.go`: `ami_type`, `instance_types`, `node_group_name_prefix` are `ForceNew`
- `terraform-aws-modules/eks` 21.29.0 `modules/eks-managed-node-group`: `use_name_prefix` default `true`, `create_before_destroy = true`
- CircleCI resource classes page: x86 Docker medium 10 credits/min, Arm Docker medium 13, Arm Linux VM medium 10
- CircleCI "Building Docker images for multiple OS architectures" (machine executor + `tonistiigi/binfmt`)
- `automation-calculator` PR #195 (2026-05-08): `--multi-platform` build and push
