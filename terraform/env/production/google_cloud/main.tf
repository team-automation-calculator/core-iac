module "organization" {
  domain      = var.google_cloud_organization_domain
  iam_members = var.organization_iam_members
  source      = "../../../modules/google_cloud/organization"
}

module "project" {
  enabled_apis = var.enabled_apis
  folder_id    = var.google_cloud_folder_id
  labels       = var.labels
  # The project sits directly under the organization unless a folder is named.
  org_id       = var.google_cloud_folder_id == null ? module.organization.org_id : null
  project_id   = var.google_cloud_project_id
  project_name = var.google_cloud_project_name
  service_accounts = {
    for account_id, account in var.service_accounts : account_id => {
      description   = account.description
      display_name  = account.display_name
      project_roles = account.project_roles
    }
  }
  source = "../../../modules/google_cloud/project"
}

# The project already exists (made by hand), so it is adopted into state
# rather than created. Import blocks must live in the root module. Once the
# first apply has run this block does nothing; it stays so that a rebuilt
# state adopts the project again.
#
# The organization has no import: Google creates it and the provider has no
# resource for it, so the module looks it up by domain.
import {
  to = module.project.google_project.this
  id = var.google_cloud_project_id
}

# Service accounts that were made by hand are adopted the same way, along with
# the project roles they were granted by hand. An import block fails the plan
# if its target does not exist, so only entries with import_existing = true
# get one; a service account added later is created instead.
locals {
  imported_service_accounts = {
    for account_id, account in var.service_accounts : account_id => account if account.import_existing
  }
  imported_service_account_roles = merge([
    for account_id, account in local.imported_service_accounts : {
      for role in account.project_roles : "${account_id} ${role}" => {
        email = "${account_id}@${var.google_cloud_project_id}.iam.gserviceaccount.com"
        role  = role
      }
    }
  ]...)
}

import {
  for_each = local.imported_service_accounts
  to       = module.project.google_service_account.this[each.key]
  id       = "projects/${var.google_cloud_project_id}/serviceAccounts/${each.key}@${var.google_cloud_project_id}.iam.gserviceaccount.com"
}

import {
  for_each = local.imported_service_account_roles
  to       = module.project.google_project_iam_member.service_account[each.key]
  id       = "${var.google_cloud_project_id} ${each.value.role} serviceAccount:${each.value.email}"
}
