variable "auto_create_network" {
  default     = true
  description = "Only read when a project is created. Kept at the provider default so an imported project plans no change."
  type        = bool
}

variable "enabled_apis" {
  default     = []
  description = "Google Cloud APIs to keep enabled on the project, e.g. admin.googleapis.com. Removing one stops managing it; it is not disabled."
  type        = set(string)
}

variable "folder_id" {
  default     = null
  description = "Numeric ID of the folder the project sits in. Set this or org_id, not both; leave both null for a project with no parent."
  type        = string
}

variable "labels" {
  default     = {}
  description = "Labels on the project. Authoritative: a label added in the console is removed on the next apply."
  type        = map(string)
}

variable "org_id" {
  default     = null
  description = "Numeric ID of the organization the project sits directly under. Set this or folder_id, not both; leave both null for a project with no parent."
  type        = string

  validation {
    condition     = var.org_id == null || var.folder_id == null
    error_message = "Set org_id or folder_id, not both."
  }
}

variable "project_id" {
  description = "The project ID (not the number, not the display name). Immutable."
  type        = string
}

variable "project_name" {
  description = "Display name of the project."
  type        = string
}
