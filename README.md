# core-iac
Infrastructure as Code for all apps within this project, including the main one.

# Setup
1. Create a TF cloud account/organization manually
2. Create a workspace for the "tf workspaces" module call for your given environment, like dev/staging/prod/etc
3. Create a variable set with valid `TFE_TOKEN` and `TF_VAR_GITHUB_TOKEN` values.
4. Execute tf plan/apply on for the workspace above to create the terraform cloud workspaces for each layer in the env
5. Apply base layer from its workspace
6. Apply cluster addons layer from its workspace
7. Profit?
