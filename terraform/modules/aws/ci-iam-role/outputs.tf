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
