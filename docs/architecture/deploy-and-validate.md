# How app and infra code is validated and deployed

**Nothing deploys from a draft PR.** A draft PR, or any PR, only runs validation:

- CircleCI checks.
- Terraform Cloud **speculative** plans, posted as commit statuses.

The only thing that changes an environment is merging to `main` in this repo. The app repo's `main` publishes an image, but that image reaches a cluster only through a core-iac PR.

## End to end

```mermaid
flowchart LR
    subgraph app["automation-calculator repo"]
        apr["App PR (draft or ready)"]
        amain["merge to main"]
    end
    subgraph hub["Docker Hub"]
        img[("automationcalculationsci/automation-calculator<br/>tag 0.9.6-&lt;CircleCI build&gt;")]
    end
    subgraph iac["core-iac repo"]
        bump["Image bump PR<br/>app_version + short_commit_hash"]
        ipr["Infra PR (draft or ready)"]
        imain["merge to main"]
    end
    subgraph tfc["Terraform Cloud"]
        stg["staging workspaces<br/>auto-apply"]
        prd["production workspaces<br/>apply pending, human confirm"]
    end

    apr -->|CircleCI build, lint, test, build prod image, no push| apr
    apr --> amain -->|CircleCI tags and pushes| img
    img -->|watch_app_docker_image_versions.py or bump script| bump
    bump --> imain
    ipr --> imain
    imain --> stg
    imain --> prd
    stg -->|staging verified first| prd
```

## App PR (automation-calculator repo)

```mermaid
sequenceDiagram
    actor Dev
    participant GH as GitHub (app repo)
    participant CCI as CircleCI build_verify_push
    participant DH as Docker Hub

    Dev->>GH: push branch, open draft PR
    GH->>CCI: pipeline on every push
    CCI->>CCI: ./go build ci (test image)
    CCI->>CCI: ./go lint ci
    CCI->>CCI: ./go test ci
    CCI->>CCI: ./go build prod (prove the prod image builds)
    Note over CCI: branch is not main:<br/>skip tag, login and push
    CCI-->>GH: commit status on the PR
    Dev->>GH: mark ready, review, merge
    GH->>CCI: pipeline on main
    CCI->>CCI: build, lint, test, build prod
    CCI->>CCI: ./go tag as 0.9.6-<build number>
    CCI->>DH: ./go push
```

Branch builds never publish a tag shaped like `0.9.6-<n>`, because every such tag becomes a deploy PR in core-iac.

## Infra PR validation (this repo)

```mermaid
sequenceDiagram
    actor Dev
    participant GH as GitHub (core-iac)
    participant CCI as CircleCI workflow validate
    participant TFC as Terraform Cloud
    participant DH as Docker Hub API

    Dev->>GH: push branch, open draft PR against main
    par CircleCI
        GH->>CCI: pipeline
        CCI->>CCI: helm lint helm/automation-calculator --strict
        CCI->>CCI: terraform fmt + validate for every module and env config
        CCI->>CCI: validate_python: ./go lint (compile, Black, Ruff, bash -n) and ./go test (pytest)
        CCI->>DH: validate_app_docker_image_versions: every added app_version tag exists (non-main only)
        CCI-->>GH: one ci/circleci status per job
    and Terraform Cloud
        GH->>TFC: VCS webhook
        Note over TFC: only workspaces whose trigger_prefixes match changed paths<br/>(working dir + module dirs, chart dir for cluster_addons)
        TFC->>TFC: speculative plan per matching workspace, staging and production
        TFC-->>GH: Terraform Cloud/... status with "N to add, N to change, N to destroy"
    end
    Dev->>GH: compare plan summary with the PR's Expected plan section
```

Notes:

- **The plan runs regardless of draft state.** A draft gets the same speculative plans as a ready PR. Plans are never applied.
- **Stacked PRs whose base is not `main` get CircleCI only.** Terraform Cloud plans only PRs against the workspace's branch, `main`.
- **Docs-only or scripts-only PRs get no Terraform Cloud status.** No workspace `trigger_prefixes` match their paths.

Which workspace a path triggers:

| Changed path | Workspace(s) planned |
|---|---|
| `terraform/env/<env>/aws/us-west-1/base-cluster-layer`, `modules/aws/networking`, `modules/aws/base-cluster-layer` | `ac_app_<env>_base_cluster_layer` |
| `terraform/env/<env>/aws/us-west-1/cluster-addons-layer`, `modules/aws/cluster-addons-layer`, `modules/aws/main_rails_app`, `helm/automation-calculator` | `ac_app_<env>_cluster_addons_layer` |
| `terraform/env/production/aws/us-east-1/route53-domains` | `ac_app_production_route53_domains` |
| `terraform/env/production/github/org`, `modules/github/org-ci-access` | `ac_app_production_github_org` |

## Merge and promotion

```mermaid
sequenceDiagram
    actor Op as Operator
    participant GH as GitHub main
    participant S as TFC staging workspaces
    participant P as TFC production workspaces
    participant Env as staging / production

    Op->>Env: before-snapshot (env_snapshot.py, /health, smoke tests)
    Op->>GH: merge PR
    GH->>S: real run
    S->>S: plan + auto-apply (3 to 5 min)
    Note over S: base_cluster_layer apply queues<br/>cluster_addons_layer via run trigger
    S->>Env: apply to staging
    Op->>Env: after-snapshot on staging, diff against PR expectation
    GH->>P: real run
    P->>P: plan, then stop at "apply pending"
    Note over P: the run embeds a ~15 min EKS token:<br/>confirm promptly or discard and re-run
    Op->>P: confirm in the TFC UI (only after staging matches)
    P->>Env: apply to production
    Op->>Env: after-snapshot on production, tick PR test-plan items
```

The operator steps are run by the `deploy-image` skill (image bumps) and the `validate-infra-rollout` skill (Terraform and Helm changes), both in `.claude/skills/`. The helper scripts they call live in `scripts/`:

- `wait_commit_status.py`
- `env_snapshot.py`
- `pr_checklist.py`
