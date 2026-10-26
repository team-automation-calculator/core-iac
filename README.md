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
7. Apply cluster addons layer from its workspace
8. Profit?

# AWS CLI Access

Human AWS access is IAM Identity Center (SSO) only — no IAM user access keys.
See [docs/aws-sso-auth.md](docs/aws-sso-auth.md) for setup and the profile reference.
