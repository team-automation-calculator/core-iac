# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure as Code for the [automation-calculations.io](https://automation-calculations.io) platform. Manages AWS EKS clusters, networking, and Kubernetes add-ons across dev/staging/prod environments, plus the Helm chart for the main Rails application.

## Repository Layout

```
terraform/
  modules/
    tf_cloud/tf_cloud_workspaces/   # TFE workspace module
    aws/
      base-cluster-layer/           # VPC, EKS cluster, IAM
      cluster-addons-layer/         # ALB controller, external-dns, metrics-server, CloudWatch alarms
      main_rails_app/               # Rails app Helm release module
      networking/                   # VPC/subnet resources
  env/              # Per-environment configs (development, staging, production)
    <env>/
      tf_cloud/     # TFE workspace bootstrap (apply this first)
      aws/us-west-1/
        base-cluster-layer/
        cluster-addons-layer/
helm/
  automation-calculator/        # App Helm chart
scripts/                        # Bash helpers
eks_version_dates.json          # EKS Kubernetes version GA/EOL dates
rds_postgres_version_dates.json # RDS PostgreSQL version support timelines
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

# Format all tf files — run this before committing any .tf changes
terraform fmt -recursive terraform/

# Validate a specific config
cd terraform/env/development/aws/us-west-1/base-cluster-layer
terraform init && terraform validate

# Plan/apply (run from the relevant env directory)
terraform plan
terraform apply
```

> **Always run `terraform fmt -recursive terraform/` before committing changes to any `.tf` file.** CI runs `terraform fmt -check` and will fail if files are not formatted.

### Helm
```bash
# Lint the chart (what CI runs — note the --strict flag)
helm lint helm/automation-calculator/ --strict

# Render templates locally
helm template automation-calculator helm/automation-calculator/ --values helm/automation-calculator/values.yaml
```

### Scripts
```bash
scripts/infra_eng_sso.py                       # SSO login + kubectl setup: writes AWS profiles, runs aws sso login, updates kubeconfig
scripts/update_kubeconfigs.sh                  # Refresh kubeconfig for all envs
scripts/launch_psql_pod.sh                     # Launch a psql pod to connect to RDS
scripts/bump_app_docker_image_version.sh       # Bump app Docker image version in Helm values + Terraform
scripts/bump_app_docker_image_version_branch.sh  # Same, but creates a git branch
scripts/check_app_docker_image_versions.py     # CI: validate added app_version values exist on Docker Hub
scripts/sort_tfvars.sh                         # Sort terraform.tfvars files alphabetically
scripts/install_tf.sh                          # Install a specific Terraform version
scripts/delete_first_eks_cluster.sh            # Delete the first EKS cluster (dev utility)
```

## Key Conventions

- **Resource naming prefix**: `ac_` (automation-calculator)
- **Project tag**: `automation_calculator`
- **Kubernetes namespaces**: `automation-calculator` (app), `kube-system` (add-ons)
- **AWS region**: `us-west-1` for all environments
- **Terraform backend**: Terraform Cloud, org `team-automation-calculator`

## Provider Versions

| Provider | Module constraint | Env config constraint |
|----------|------------------|-----------------------|
| AWS | `~> 6.0` | `~> 6.0` |
| Helm | `~> 2.9` | `~> 2.9` |
| Kubernetes | `~> 2.16` | `~> 2.16` |
| TFE | — | `0.68.2` (pinned exactly in all tf_cloud configs) |

Lock files (`.terraform.lock.hcl`) are committed in every module and env config directory. All lock files use `registry.terraform.io` (HashiCorp Terraform). When updating providers, run `terraform init -upgrade` in module directories and `terraform init -upgrade -backend=false` in env config directories (env configs require TFE_TOKEN for normal init), then commit the updated lock files alongside the `versions.tf` changes.

## External-DNS Helm Registry

External-DNS uses the Bitnami OCI registry (`oci://registry-1.docker.io/bitnamicharts`), not the legacy HTTP repo. Use `chart = "external-dns"` with `repository = "oci://registry-1.docker.io/bitnamicharts"` in any `helm_release` resource.

## Pull Requests

**Never push directly to `main`.** All changes must go through a branch and a pull request, even small ones. Use the `hub` CLI (not `gh`) for all GitHub pull request operations:

```bash
# Create a draft PR
hub pull-request --draft --message "Title

Body line 1
Body line 2"

# Create a ready PR
hub pull-request --message "Title

Body"
```

## Required Environment Variables

```
TFE_TOKEN                  # Terraform Cloud API token
TF_VAR_GITHUB_TOKEN        # GitHub token (passed as TF variable)
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```
