variable "members" {
  default     = {}
  description = "Terraform Cloud organization members, keyed by a short stable name (e.g. \"ci\"). email is the address of the member's HCP Terraform account; owner adds the member to the owners team. The key is only a Terraform address: renaming it removes and re-invites the member."
  type = map(object({
    email = string
    owner = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for member in values(var.members) : can(regex("^[^@\\s/]+@[^@\\s/]+$", member.email))])
    error_message = "Each member email must be a single address with no whitespace or slash."
  }

  validation {
    condition     = length(distinct([for member in values(var.members) : lower(member.email)])) == length(var.members)
    error_message = "Each member email must appear only once."
  }
}

variable "organization_name" {
  description = "The Terraform Cloud organization whose members are managed."
  type        = string
}
