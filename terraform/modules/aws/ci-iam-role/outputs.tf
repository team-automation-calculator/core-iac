output "role_arn" {
  description = "The ARN of the CI IAM role."
  value       = aws_iam_role.ci.arn
}

output "role_name" {
  description = "The name of the CI IAM role."
  value       = aws_iam_role.ci.name
}

output "policy_arn" {
  description = "The ARN of the IAM policy attached to the CI role."
  value       = aws_iam_policy.ci.arn
}

output "read_only_role_arn" {
  description = "The ARN of the read-only CI IAM role."
  value       = aws_iam_role.ci_read_only.arn
}

output "read_only_role_name" {
  description = "The name of the read-only CI IAM role."
  value       = aws_iam_role.ci_read_only.name
}

output "read_only_policy_arn" {
  description = "The ARN of the IAM policy attached to the read-only CI role."
  value       = aws_iam_policy.ci_read_only.arn
}
