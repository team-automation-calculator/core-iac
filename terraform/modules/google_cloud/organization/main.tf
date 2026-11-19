# The Google Cloud organization for a Workspace domain.
#
# Google creates the organization itself, the first time someone from the
# domain uses Google Cloud. No API creates, renames or deletes one and the
# provider has no organization resource, so there is nothing to import: the
# organization is looked up by domain, and what Terraform manages is what
# hangs off it (IAM grants here, the project in ../project).
data "google_organization" "this" {
  domain = var.domain
}

# Additive, one grant per entry: these never remove a grant made elsewhere,
# and adding a grant that already exists changes nothing. The authoritative
# google_organization_iam_policy / _binding resources are avoided on purpose:
# a list that misses one existing grant would lock people out of the
# organization.
resource "google_organization_iam_member" "grant" {
  for_each = { for grant in var.iam_members : "${grant.role} ${grant.member}" => grant }

  member = each.value.member
  org_id = data.google_organization.this.org_id
  role   = each.value.role
}
