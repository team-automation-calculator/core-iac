# core-iac
Infrastructure as Code for all apps within this project, including the main one.

[Here is a link to the generated website](https://automation-calculations.io)

# Setup
1. Create a TF cloud account/organization manually
2. Create a workspace for the "tf workspaces" module call for your given environment, like dev/staging/prod/etc
3. Create a variable set with valid `TFE_TOKEN` and `TF_VAR_GITHUB_TOKEN` values.
4. Link variable set to that TFE workspace
5. Execute tf plan/apply on for the workspace above to create the terraform cloud workspaces for each layer in the env
   - For production this also creates the `ac_app_production_github_org` workspace. Set a sensitive `GITHUB_TOKEN` environment variable on it (an org owner's fine-grained PAT, see [docs/github-ci-user.md](docs/github-ci-user.md)) before its first run.
6. Apply base layer from its workspace
7. Apply cluster addons layer from its workspace. With `argocd_enabled = true` in its `terraform.tfvars` this also installs ArgoCD and the app's `AppProject` and `Application` (`terraform/modules/kubernetes/argocd`); the `main_rails_app` module in the same layer creates the app namespace, its Secret, RDS and the ACM certificate, but not the app itself.
8. Deploy the app. ArgoCD deploys `helm/automation-calculator` from `main`; Terraform has not managed the app's Helm release since the ArgoCD migration ([docs/argocd-migration-plan.md](docs/argocd-migration-plan.md)). An image bump is a PR from `scripts/bump_app_docker_image_version_branch.sh` (it edits the chart's `values-<env>.yaml`, never `terraform.tfvars`); staging syncs it automatically after the merge, production needs `argocd app sync automation-calculator` through a port-forward ([docs/argocd-phase-8-production.md](docs/argocd-phase-8-production.md), section 8). The exact flow is in `CLAUDE.md` under "Deploying the app".
9. Profit?

# AWS CLI Access

Human AWS access is IAM Identity Center (SSO) only — no IAM user access keys.
See [docs/aws-sso-auth.md](docs/aws-sso-auth.md) for setup and the profile reference.
