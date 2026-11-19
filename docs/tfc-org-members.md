# Terraform Cloud Organization Members

Who is in the `team-automation-calculator` Terraform Cloud (HCP Terraform)
organization is Terraform-managed: organization memberships and membership of
the `owners` team (`terraform/modules/tf_cloud/tf_cloud_org_members`, applied
from `terraform/env/production/tf_cloud`). The organization is global, so it is
managed once, from production.

The accounts *themselves* are not. HashiCorp has no API for creating a user
account, choosing its sign-in method, or accepting an invitation, so those
steps are by hand, below.

## The 31 January 2027 sign-in change

HashiCorp removes email-and-password sign-in from HCP on **31 January 2027**.
Before then every account needs IBMid or GitHub added as a sign-in method
(<https://developer.hashicorp.com/hcp/docs/hcp/create-account>):

- An IBMid whose email **matches** the account's email is attached to the
  existing account automatically. Memberships and roles are unchanged and
  nothing in Terraform changes.
- An IBMid with a **different** email, or any IBMid for an account that signs
  in with GitHub only, creates a separate, empty account. That account is then
  a new member: add it to `tfc_organization_members`, apply, accept the
  invitation, and remove the old entry in a later change.

Per account, once, by hand:

1. Sign in at <https://app.terraform.io> the existing way and confirm the
   account's email under Account settings.
2. Sign out. On the sign-in page choose the IBMid option and its link to create
   an IBMid. Register with exactly the email of the existing HCP Terraform
   account. Password and MFA secret go in the team password manager.
3. Sign in at <https://app.terraform.io> with IBMid and confirm the account
   lands in `team-automation-calculator` with its workspaces, not in a new
   empty account. If it is empty, the emails did not match: sign back in the
   old way and treat the IBMid account as a new member (below).
4. From then on sign in with IBMid only.

## Configuration

`tfc_organization_members` in `terraform/env/production/tf_cloud` is a map
keyed by a short stable name:

```hcl
tfc_organization_members = {
  ci = {
    email           = "ci@example.net"
    import_existing = true
    owner           = true
  }
}
```

- `email`: the address of the member's HCP Terraform account.
- `owner`: adds the member to the `owners` team. Custom teams are not managed
  here.
- `import_existing`: set to `true` for someone who is **already** a member
  (and, when `owner = true`, already in the owners team). The membership is
  then imported into state instead of re-invited. Leave it `false` for a new
  invitee: an import of something that does not exist fails the plan. The flag
  can stay `true` after the import has been applied.

The member list lives in `terraform/env/production/tf_cloud/terraform.tfvars`,
so every change to it is a reviewed pull request. This repository is public,
so the addresses are too; that was accepted (2026-11-18). Do not also set an
HCL variable named `tfc_organization_members` on the workspace: it would
override the file.

## Adopt the current members (first apply)

1. In the TFC UI, Organization settings → Users, note each member's email and
   whether they are in the owners team.
2. List each one with `import_existing = true`.
3. The plan must show only imports: `N to import, 0 to add, 0 to change,
   0 to destroy`. Anything else, stop and fix the list.

## Invite a member

1. Add an entry without `import_existing`. Apply.
2. The person accepts the invitation from the email, signing in with IBMid.
3. `terraform output tfc_organization_members` (or the workspace's outputs
   page) shows a `username` once the invitation is accepted.

## Remove a member

Delete the entry and apply. **This removes the user from the organization**,
along with their access to every workspace; their user API tokens stop working
for this organization. Check first that no automation runs on that user's
token (the `TFE_TOKEN` variable set in particular). HCP Terraform refuses to
remove the last owner.

Members not listed in the variable are left alone: Terraform only manages what
is in the map.

## Notes

- Renaming a map key is a remove plus a re-invite. Add a `moved` block, or keep
  the key.
- An account's email cannot be changed through Terraform; only its owner can
  change it. A changed address shows as a replace (remove and re-invite).
- The token the workspace runs with needs owner rights: an owner's user token,
  the owners team token, or the organization token.
- The production `tf_cloud` workspace (`ac_app_production_tf_workspaces`) is
  hand-made, so its Terraform version is set in the TFC UI (Settings → General),
  not by this repo. It must be 1.7 or newer for the `import` blocks; keep it on
  the same version as the workspaces it creates (`tfe_workspace_tf_version`).
  The same holds for `ac_app_staging_tf_workspaces` and
  `ac_app_development_tf_workspaces`. All three were set to Terraform 1.17.0 in
  the UI on 2026-11-18; before that the production one predated `import`
  blocks (Terraform 1.5).
- If the production `tf_cloud` workspace does not start a run on a change to
  `terraform/modules/tf_cloud/tf_cloud_org_members`, queue one by hand.
