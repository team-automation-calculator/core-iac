variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "app_log_retention_days" {
  default     = 90
  description = "Days CloudWatch Logs keeps the app's log events. Must be a value CloudWatch accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, ...)."
  type        = number
}

variable "app_logs_enabled" {
  default     = false
  description = "Ship the app namespace's pod logs to the CloudWatch Logs group /ac/<environment>/app with a Fluent Bit DaemonSet (plans/app-log-persistence.md). Setting it back to false deletes the group and its contents."
  type        = bool
}

variable "app_server_error_alarm_threshold" {
  default     = 1
  description = "Number of 5xx responses logged by the app in 5 minutes that puts the app-server-errors alarm in ALARM. Only used when both app_logs_enabled and cloudwatch_alarms_enabled are true."
  type        = number
}

variable "ci_read_only_kubernetes_group" {
  description = "Kubernetes group the read-only CI role is mapped to by its EKS access entry; granted cluster-scoped read on nodes"
  type        = string
}

variable "cloudwatch_alarms_enabled" {
  description = "Set to true to create the CloudWatch alarms and SNS alerting resources. Requires the app ALB to exist, so must be false on initial bootstrap."
  type        = bool
  default     = false
}

variable "environment_name" {
  default     = "development"
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

# external-dns expands "%{record_type}" in the prefix, but "%{" starts a
# Terraform template directive: in .tf/.tfvars write it as "%%{record_type}".
variable "external_dns_txt_prefix" {
  default     = ""
  description = "external-dns --txt-prefix for its TXT ownership records. Empty leaves it unset (chart default). Changing it requires the Route 53 migration in docs/external-dns-txt-prefix-migration.md."
  type        = string
}

variable "eks_cluster_api_endpoint" {
  description = "The api endpoint of the EKS cluster to install addons into."
  type        = string
}

variable "eks_cluster_cert_data" {
  description = "The cert data of the EKS cluster to install addons into."
  type        = string
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster to install addons into."
  type        = string
}

variable "eks_cluster_oidc_provider_arn" {
  description = "The OIDC provider ARN of the EKS cluster to install addons into."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID of the VPC to put the app into"
  type        = string
}
