# Who may sign in to AWS, as a Google group.
#
# Google exposes no API for a SAML app's own settings (ACS URL, Entity ID,
# certificate, Name ID, user access), so those stay hand-made and are recorded
# in iac/specs/sso/google-workspace-saml.json. What the Admin SDK does expose
# is the directory, so the list of people allowed through the app lives here:
# the app's User access is turned ON for this group (once, by hand) and
# membership is then changed by pull request.
resource "googleworkspace_group" "aws_identity_center" {
  description = var.group_description
  email       = var.group_email
  name        = var.group_name
}

# Authoritative: a member added in the Admin console is removed on the next
# apply.
resource "googleworkspace_group_members" "aws_identity_center" {
  group_id = googleworkspace_group.aws_identity_center.id

  dynamic "members" {
    for_each = var.member_emails
    content {
      email = members.value
      role  = "MEMBER"
      type  = "USER"
    }
  }
}
