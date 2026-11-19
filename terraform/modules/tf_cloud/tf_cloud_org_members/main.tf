# One organization membership per entry in var.members. For an address that is
# not in the organization yet this sends an invitation; the person accepts it
# once by hand (docs/tfc-org-members.md). Removing an entry removes that user
# from the organization.
resource "tfe_organization_membership" "member" {
  for_each     = var.members
  organization = var.organization_name
  email        = each.value.email
}

# The owners team exists in every organization and cannot be created or deleted.
data "tfe_team" "owners" {
  count        = length(local.owners) > 0 ? 1 : 0
  name         = "owners"
  organization = var.organization_name
}

# One resource per owner, rather than tfe_team_organization_members for the
# whole team, so that an owner who is not listed in var.members yet is left
# alone instead of being removed from the owners team.
resource "tfe_team_organization_member" "owner" {
  for_each                   = local.owners
  team_id                    = data.tfe_team.owners[0].id
  organization_membership_id = tfe_organization_membership.member[each.key].id
}
