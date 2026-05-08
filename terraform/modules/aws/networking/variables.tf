# Declare vars
variable "availability_zones" {
  type    = list(string)
  default = ["us-west-1a", "us-west-1c"]
}

variable "environment_name" {
  type = string
}
