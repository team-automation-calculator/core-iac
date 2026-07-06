output "permission_set_arn" {
  description = "The ARN of the InfraEng permission set."
  value       = aws_ssoadmin_permission_set.infra_eng.arn
}

output "permission_set_name" {
  description = "The name of the InfraEng permission set."
  value       = aws_ssoadmin_permission_set.infra_eng.name
}

output "read_only_permission_set_arn" {
  description = "The ARN of the read-only InfraEng permission set."
  value       = aws_ssoadmin_permission_set.infra_eng_read_only.arn
}

output "read_only_permission_set_name" {
  description = "The name of the read-only InfraEng permission set."
  value       = aws_ssoadmin_permission_set.infra_eng_read_only.name
}
