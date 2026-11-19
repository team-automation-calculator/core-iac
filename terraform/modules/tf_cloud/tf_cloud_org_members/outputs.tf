output "members" {
  description = "Managed organization members by key: membership ID, username (null until the invitation is accepted) and whether the member is in the owners team."
  value = {
    for key, membership in tfe_organization_membership.member : key => {
      membership_id = membership.id
      owner         = var.members[key].owner
      username      = membership.username
    }
  }
}
