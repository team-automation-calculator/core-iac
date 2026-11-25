locals {
  owners = { for key, member in var.members : key => member if member.owner }
}
