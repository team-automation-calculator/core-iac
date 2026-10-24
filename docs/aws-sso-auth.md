# AWS Authentication: IAM Identity Center (SSO) Only

Human AWS access to this project uses **IAM Identity Center (SSO) exclusively**.
IAM users and long-lived access keys are not used for human access — do not
create them, and never set `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in your
shell or `~/.aws/credentials`.

Every credential in the human path is a short-lived STS token:

```
Google Workspace login
  → IAM Identity Center (SSO)                     aws sso login
    → InfraEng<Env>[ReadOnly] permission set      sso_role_name
      → ac_ci_terraform_<env>[_read_only] role    chained via role_arn/source_profile
```

The `InfraEng<Env>` permission sets and the trust policies that let them assume
the CI roles are managed in Terraform (`terraform/modules/aws/sso-infra-eng`
and `terraform/modules/aws/ci-iam-role`, wired per environment in
`terraform/env/<env>/aws/us-west-1/base-cluster-layer`).

## One-time setup

Requires AWS CLI v2. Either run the wizard:

```bash
aws configure sso   # start URL: your Identity Center portal URL; SSO region: us-east-1
```

or paste the config below into `~/.aws/config`, filling in the account ID and
start URL (find them in the Identity Center console or ask an existing infra
engineer — this repo is public, so they are not committed here). The start URL
is the **AWS access portal URL**, which comes in two forms depending on the
instance: `https://<subdomain>.awsapps.com/start` or the newer
`https://ssoins-<id>.portal.<region>.app.aws`.

```ini
# One SSO session shared by all profiles: a single login covers everything.
[sso-session ac]
sso_start_url = <AWS_ACCESS_PORTAL_URL>
sso_region = us-east-1
sso_registration_scopes = sso:account:access

# SSO login profiles — one per environment's InfraEng permission set.
[profile infra-eng-dev]
sso_session = ac
sso_account_id = <ACCOUNT_ID>
sso_role_name = InfraEngDevelopment
region = us-west-1

[profile infra-eng-staging]
sso_session = ac
sso_account_id = <ACCOUNT_ID>
sso_role_name = InfraEngStaging
region = us-west-1

[profile infra-eng-production]
sso_session = ac
sso_account_id = <ACCOUNT_ID>
sso_role_name = InfraEngProduction
region = us-west-1

# Read-only personas: plans, inspection, kubeconfig updates — no writes.
[profile infra-eng-staging-ro]
sso_session = ac
sso_account_id = <ACCOUNT_ID>
sso_role_name = InfraEngStagingReadOnly
region = us-west-1

# Chained CI role profiles — what Terraform/AWS CLI work should run as.
# Each assumes the environment's CI role using the SSO profile's credentials.
[profile ac-ci-dev]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/ac_ci_terraform_development
source_profile = infra-eng-dev
region = us-west-1

[profile ac-ci-staging]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/ac_ci_terraform_staging
source_profile = infra-eng-staging
region = us-west-1

[profile ac-ci-production]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/ac_ci_terraform_production
source_profile = infra-eng-production
region = us-west-1

[profile ac-ci-staging-ro]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/ac_ci_terraform_staging_read_only
source_profile = infra-eng-staging-ro
region = us-west-1
```

Add `-ro` profile pairs for other environments as their read-only permission
sets are provisioned, following the staging pattern above.

## Daily use

```bash
aws sso login --profile infra-eng-staging   # one browser login covers all profiles

AWS_PROFILE=ac-ci-staging aws sts get-caller-identity   # verify the chain
AWS_PROFILE=ac-ci-staging terraform plan                # terraform against an env
AWS_PROFILE=ac-ci-staging scripts/update_kubeconfigs.sh # refresh kubeconfigs
AWS_PROFILE=ac-ci-staging kubectl get nodes             # kubectl (read-write role only)
```

Prefer the `-ro` profiles for anything that only reads (plans, inspection,
`update_kubeconfigs.sh`).

## Troubleshooting

**Browser shows "Something doesn't compute — We couldn't verify your sign-in
credentials" during `aws sso login`.** The local config is usually not the
problem: `aws sso login` builds the authorization URL from a client it
registers fresh, and this error page comes from the AWS sign-in service later
in the browser flow — stale Identity Center / AWS sign-in session state in the
browser, or Google federating the wrong account. In order:

1. Retry in a private/incognito window and pick your **Workspace** account in
   the Google sign-in (not a personal Google account).
2. If a normal window is needed, clear cookies for `awsapps.com`,
   `signin.aws.amazon.com`, and `aws.amazon.com`, then retry.
3. Only if it persists in a private window, re-check the config: `sso_start_url`
   must be the access portal URL (`https://<subdomain>.awsapps.com/start` or
   `https://ssoins-<id>.portal.<region>.app.aws`) and `sso_region` must be the
   Identity Center home region (`us-east-1`).

## What is NOT used

- **IAM users / access keys for humans** — none. If you find a human-use IAM
  user or an active access key for one, deactivate and delete it.
- **`~/.aws/credentials`** — should not exist, or should be empty.
- The one legitimate access-key holder is Terraform Cloud: its remote runs
  authenticate via workspace variables managed in TFC, never locally.
