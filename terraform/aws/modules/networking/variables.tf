# Declare vars
variable "environment_name" {
  type = string
}

variable "availability_zones" {
  type    = list
  default = ["us-west-1a", "us-west-1c"]
}
