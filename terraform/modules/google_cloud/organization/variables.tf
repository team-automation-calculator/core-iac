variable "domain" {
  description = "Primary domain of the Google Workspace account that owns the organization, e.g. automation-calculations.net."
  type        = string
}

variable "iam_members" {
  default     = []
  description = "Organization-level IAM grants to keep in place, e.g. { role = \"roles/resourcemanager.organizationAdmin\", member = \"user:someone@example.com\" }. Additive: removing an entry removes that one grant, and grants not listed are left alone."
  type = set(object({
    member = string
    role   = string
  }))
}
