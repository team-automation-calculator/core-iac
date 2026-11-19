# Service accounts in the project. Their keys are not managed: a key made
# here would put the private key in Terraform state.
resource "google_service_account" "this" {
  for_each = var.service_accounts

  account_id   = each.key
  description  = each.value.description
  display_name = coalesce(each.value.display_name, each.key)
  project      = google_project.this.project_id
}

locals {
  service_account_project_roles = merge([
    for account_id, account in var.service_accounts : {
      for role in account.project_roles : "${account_id} ${role}" => {
        account_id = account_id
        role       = role
      }
    }
  ]...)
}

# Additive, one grant per role: these never remove a grant made elsewhere.
# Taking a role off a service account's list removes that grant, so removing
# roles/owner from the account the workspace runs as locks Terraform out of
# the project until someone grants it again by hand.
resource "google_project_iam_member" "service_account" {
  for_each = local.service_account_project_roles

  member  = google_service_account.this[each.value.account_id].member
  project = google_project.this.project_id
  role    = each.value.role
}
