# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure as Code for the [automation-calculations.io](https://automation-calculations.io) platform. Manages AWS EKS clusters, networking, and Kubernetes add-ons across dev/staging/prod environments, plus the Helm chart for the main Rails application.

## Repository Layout

```
terraform/
  modules/          # Reusable modules (tf_cloud, aws/*)
  env/              # Per-environment configs (development, staging, production)
    <env>/
      tf_cloud/     # TFE workspace bootstrap (apply this first)
      aws/us-west-1/
        base-cluster-layer/     # VPC, EKS cluster, IAM
        cluster-addons-layer/   # ALB controller, external-dns, metrics-server
helm/
  automation-calculator/        # App Helm chart
scripts/                        # Bash helpers (version bump, kubeconfig, db connect)
.circleci/config.yml            # CI validation pipeline
```

## Layered Apply Order

Each environment must be applied in order:
1. `terraform/env/<env>/tf_cloud/` — creates TFE workspaces
2. `base-cluster-layer` — VPC, subnets, NAT gateway, EKS cluster, IAM IRSA roles
3. `cluster-addons-layer` — Helm-deployed add-ons (ALB controller, external-dns, metrics-server)

## Common Commands

### Terraform
```bash
# Format check (what CI runs)
terraform fmt -check -recursive terraform/

# Validate a specific config
cd terraform/env/development/aws/us-west-1/base-cluster-layer
terraform init && terraform validate

# Plan/apply (run from the relevant env directory)
terraform plan
terraform apply
```

### Helm
```bash
# Lint the chart (what CI runs)
helm lint helm/automation-calculator/

# Render templates locally
helm template automation-calculator helm/automation-calculator/ --values helm/automation-calculator/values.yaml
```

### Scripts
```bash
scripts/update_kubeconfigs.sh   # Refresh kubeconfig for all envs
scripts/connect_to_db.sh        # Port-forward to RDS via kubectl
scripts/bump_version.sh         # Bump app version across chart/manifests
```

## Key Conventions

- **Resource naming prefix**: `ac_` (automation-calculator)
- **Project tag**: `automation_calculator`
- **Kubernetes namespaces**: `automation-calculator` (app), `kube-system` (add-ons)
- **AWS region**: `us-west-1` for all environments
- **Terraform backend**: Terraform Cloud, org `team-automation-calculator`

## Provider Versions

| Provider | Constraint |
|----------|-----------|
| AWS | `~> 4.47` |
| TFE | `0.68.2` (pinned exactly) |
| Helm | `~> 2.9` |
| Kubernetes | defined per module |

Lock files (`.terraform.lock.hcl`) are committed. When updating providers, run `terraform init -upgrade` in each affected directory and commit the updated lockfile alongside the `versions.tf` change.

## External-DNS Helm Registry

External-DNS uses the Bitnami OCI registry (`oci://registry-1.docker.io/bitnamicharts`), not the legacy HTTP repo. Use `chart = "external-dns"` with `repository = "oci://registry-1.docker.io/bitnamicharts"` in any `helm_release` resource.

## Required Environment Variables

```
TFE_TOKEN                  # Terraform Cloud API token
TF_VAR_GITHUB_TOKEN        # GitHub token (passed as TF variable)
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```
