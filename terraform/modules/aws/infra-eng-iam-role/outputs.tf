output "role_arn" {
  description = "The ARN of the infra_eng IAM role."
  value       = aws_iam_role.infra_eng.arn
}

output "role_name" {
  description = "The name of the infra_eng IAM role."
  value       = aws_iam_role.infra_eng.name
}

output "user_arn" {
  description = "The ARN of the infra engineer IAM user."
  value       = aws_iam_user.infra_eng.arn
}

output "user_name" {
  description = "The name of the infra engineer IAM user."
  value       = aws_iam_user.infra_eng.name
}
