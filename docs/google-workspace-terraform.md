# Google Workspace in Terraform

Google Workspace is the identity provider for AWS sign-in (see
`docs/aws-sso-auth.md`). This page covers the part of it that Terraform can
manage, how to turn that on, and what has to stay manual.

## What Google lets Terraform manage

Researched 2026-11-18.

| Google Workspace object | API | In this repo |
|---|---|---|
| The **AWS Identity Center** SAML app: ACS URL, Entity ID, Start URL, certificate, Name ID, attribute mapping | None | Manual. Expected values in `iac/specs/sso/google-workspace-saml.json` |
| The app's **User access** (ON/OFF per organizational unit or group) | None | Manual |
| Auto-provisioning (SCIM) to Identity Center | None | Manual |
| Groups and group membership | Admin SDK Directory API | `terraform/modules/google_workspace/aws-identity-center-access` |
| Users, organizational units, admin roles | Admin SDK Directory API | Not managed (see below) |

Why the SAML app is manual:

- The Admin SDK Directory API covers users, groups, organizational units,
  roles, schemas, domains and devices. It has no SAML app resource.
- The Cloud Identity API has `inboundSamlSsoProfiles`, but that is the opposite
  direction: an outside identity provider signing users in to Google.
- The Cloud Identity Policy API lists the settings it can read or write
  (<https://docs.cloud.google.com/identity/docs/concepts/supported-policy-api-settings>).
  SAML apps are not among them, and its `service_status` setting covers Google
  services only.
- No Terraform provider has a SAML app resource. `hashicorp/googleworkspace`
  was archived on 2025-06-30 (last release 0.7.0, 2022). Its maintained
  successor, `macadmins/googleworkspace`, manages users, groups, organizational
  units, domains, roles, schemas and Chrome policy.

So the one Google-side control that can move into code is **who** may use the
app: turn the app ON for a group, and manage that group's membership here.

Users are left out on purpose. The provider can manage them, but importing
human accounts (one of them the super administrator) puts their names,
recovery details and suspension state under `terraform apply`, for no gain in
a two-account Workspace.

## What the Terraform does

`terraform/env/production/google_workspace` (TFC workspace
`ac_app_production_google_workspace`) creates:

- the group `aws-identity-center@automation-calculations.net`
- its membership, from `aws_identity_center_member_emails` in `terraform.tfvars`

Membership is authoritative: a member added in the Admin console is removed on
the next apply. Every member must also exist as an IAM Identity Center user
with the same userName, and needs the `InfraEng*` assignments from
`terraform/modules/aws/sso-infra-eng`.

The workspace is created by `enable_google_workspace_workspace = true` in
`terraform/env/production/tf_cloud/terraform.tfvars`. Without the two
variables from step 2 its runs fail at the plan and change nothing. Production
workspaces do not auto-apply.

## Turning it on

Steps 1 to 3 were done on 2026-11-19: the service account lives in the Google
Cloud project `terraform-google-workspace`, and the group exists. Step 4 has
not been done, so the app is still ON for everyone. The steps are kept for a
rebuild or a key rotation. Do them in order; the last one is the only one that
can lock anyone out.

### 1. Service account (once, by hand)

1. In the Google Cloud console, create a project in the
   `automation-calculations.net` organization (the organization had none; the
   one in use is `terraform-google-workspace`). APIs can only be enabled with
   a project selected, not at the organization level. That project is imported
   into Terraform, which then keeps its APIs enabled; see
   `docs/google-cloud-terraform.md`.
2. APIs & Services → Library → enable **Admin SDK API**.
3. IAM & Admin → Service accounts → create `terraform-google-workspace`. It
   needs no Google Cloud roles. The account is now imported into Terraform
   (`service_accounts` in `terraform/env/production/google_cloud`); its key is
   not.
4. Open the service account → Keys → Add key → JSON. Keep the file out of the
   repo.
5. In Google Admin → Account → Admin roles → **Groups Admin** → Assign service
   accounts, and add the service account's email. This is a direct role
   assignment: no domain-wide delegation and no impersonated user.

### 2. Terraform Cloud workspace

1. Apply `terraform/env/production/tf_cloud` if the
   `ac_app_production_google_workspace` workspace does not exist yet (the plan
   shows one workspace to add).
2. On the new `ac_app_production_google_workspace` workspace, add:
   - environment variable `GOOGLEWORKSPACE_CREDENTIALS` (sensitive): the
     contents of the JSON key on one line. Terraform Cloud rejects an
     environment variable that contains newlines, and the downloaded key is
     pretty-printed, so collapse it first:
     `jq -c . <key-file>.json | pbcopy`
   - Terraform variable `google_workspace_customer_id`: the customer ID from
     Google Admin → Account → Account settings
3. Delete the local copy of the key.

### 3. First apply

Queue a run. The plan should show two resources to add: the group and its
members. Apply, then confirm in Google Admin → Directory → Groups that the
group exists with the expected members.

### 4. Point the app at the group (by hand)

The app's User access is **ON for everyone** today. To restrict it to the
group:

1. Confirm your own account is a member of the group. If it is not, stop.
2. Google Admin → Apps → Web and mobile apps → AWS Identity Center → User
   access → Groups → search for the group → **ON** → Save.
3. Sign in to AWS in a private window and confirm it works.
4. Only then set the organizational unit level to **OFF for everyone**.
5. Update `user_access` in `iac/specs/sso/google-workspace-saml.json`.

If sign-in fails after step 4 with "User is Unauthorized" in the Google SAML
log, set the organizational unit back to ON for everyone.

## Limits

- `macadmins/googleworkspace` is a community provider (version 1.5.3 at the
  time of writing, about a thousand downloads). The lock files pin its
  checksums.
- The service account key is a long-lived credential. It can do what the
  Groups Admin role can do: create, change and delete any group in the
  Workspace.
- Terraform cannot see whether step 4 was done. The group has no effect until
  the app is turned ON for it.
