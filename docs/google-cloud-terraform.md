# Google Cloud in Terraform

Google Cloud runs nothing for the platform. It is used for one thing: a
project that holds the service accounts Terraform signs in to Google with
(`docs/google-workspace-terraform.md`). That project, and the organization it
sits in, are managed from `terraform/env/production/google_cloud` (TFC
workspace `ac_app_production_google_cloud`).

## What the Terraform does

| Object | How | Module |
|---|---|---|
| The `automation-calculations.net` organization | Looked up by domain. Not a resource (see below) | `terraform/modules/google_cloud/organization` |
| Organization-level IAM grants | `organization_iam_members` in `terraform.tfvars`. Empty today | `terraform/modules/google_cloud/organization` |
| The project: display name, parent, labels | **Imported**, then managed | `terraform/modules/google_cloud/project` |
| The project's enabled APIs | `enabled_apis` in `terraform.tfvars` | `terraform/modules/google_cloud/project` |

**The organization cannot be created or imported.** Google creates it the
first time someone from the Workspace domain uses Google Cloud. No API
creates, renames or deletes an organization, and the `hashicorp/google`
provider has no organization resource (checked against the 8.12.0 schema: a
`google_organization` data source, and resources only for what hangs off an
organization). So the module reads it by domain and gives its ID to the
project as the project's parent.

**The project is imported, not created.** It was made by hand. The `import`
block in `main.tf` adopts it on the first apply, and `prevent_destroy` plus
`deletion_policy = "PREVENT"` stop Terraform from ever deleting it.

Not managed:

- **Billing.** `billing_account` is ignored, so Terraform neither links nor
  unlinks billing and the billing account ID stays out of this public repo.
- **Service accounts and their keys** (`terraform-google-workspace`, and the
  one this workspace runs as). Still made by hand.
- **Organization policies and folders.** There are none to speak of.
- **Disabling APIs.** Removing an API from `enabled_apis` stops managing it
  and leaves it on.

Organization IAM is additive on purpose. Each entry is one
`google_organization_iam_member`; grants made elsewhere are left alone. The
authoritative resources are avoided because a list that misses one existing
grant would lock people out.

## Turning it on

All three steps were done on 2026-11-19: the `terraform-google-cloud` service
account has Owner on the project and Organization Viewer on the organization,
and the first apply imported the project with no changes to it and added the
four `google_project_service` resources. The steps are kept for a rebuild or a
key rotation.

The project is the one named `terraform-google-workspace`, made by hand the
same day (`docs/google-workspace-terraform.md`). Its ID and display name are
set on the workspace rather than committed, because the ID Google assigned can
differ from the name.

### 1. Service account (once, by hand)

1. In the Cloud console, in the existing project, enable these APIs (APIs &
   Services → Library). Terraform keeps them enabled afterwards, but it cannot
   make its first call without them:
   - Cloud Resource Manager API
   - Service Usage API
   - Cloud Billing API (the provider reads the project's billing link on every
     refresh)
2. IAM & Admin → Service accounts → create `terraform-google-cloud`.
3. Grant it, **on the project** (IAM & Admin → IAM, with the project selected):
   - **Owner**. Reading the project and its APIs needs less (Viewer plus
     Service Usage Admin), but changing the project's name, labels or parent
     needs `resourcemanager.projects.update`, which no narrower predefined
     project role carries.
4. Grant it, **on the organization** (IAM & Admin → IAM, with the organization
   selected):
   - **Organization Viewer** (`roles/resourcemanager.organizationViewer`), so
     it can look the organization up by domain.
   - Only if `organization_iam_members` is going to be non-empty:
     **Organization Administrator**. That lets the key change who can do
     anything in the organization, so do not grant it until it is needed.
5. Open the service account → Keys → Add key → JSON. Keep the file out of the
   repo.

### 2. Terraform Cloud workspace

1. Apply `terraform/env/production/tf_cloud`. The plan shows one workspace to
   add, `ac_app_production_google_cloud`.
2. On that workspace, add:
   - environment variable `GOOGLE_CREDENTIALS` (sensitive): the contents of
     the JSON key on one line. Terraform Cloud rejects an environment variable
     that contains newlines, so collapse the downloaded key first:
     `jq -c . <key-file>.json | pbcopy`
   - Terraform variable `google_cloud_project_id`: the project ID (Cloud
     console → project picker, the ID column, not the name or the number)
   - Terraform variable `google_cloud_project_name`: the project's display
     name, exactly as shown
   - Terraform variable `google_cloud_folder_id`: only if the project sits in
     a folder rather than directly under the organization
3. Delete the local copy of the key.

### 3. First apply (the import)

Queue a run and read the plan before confirming. It should say:

- `module.project.google_project.this` **will be imported**, with no changes
  to it
- one `google_project_service` to add per entry in `enabled_apis` (adding one
  that is already enabled changes nothing in Google)
- nothing to destroy

Stop and fix the inputs, rather than applying, if the project shows an update:

| The plan wants to change | Cause | Fix |
|---|---|---|
| `name` | `google_cloud_project_name` differs from the real name | Correct the workspace variable |
| `labels` | The project has labels | Copy them into `labels` in `terraform.tfvars` |
| `org_id` / `folder_id` | The project is in a folder, or has no parent | Set `google_cloud_folder_id`; a project with no parent has to be moved into the organization first, by hand |

After the apply, a second plan should show no changes.

## Limits

- The service account key is a long-lived credential with Owner on the
  project. Anyone holding it can create keys for the other service accounts in
  the project, including the one with Groups Admin in Google Workspace.
- The lookup by domain returns the organization only if the service account
  can see it. Without Organization Viewer the plan fails with an "organization
  not found" error.
