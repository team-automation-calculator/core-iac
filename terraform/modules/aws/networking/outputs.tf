output "public_eks_subnet_ids" {
  description = "The public subnet ids in the VPC"
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "private_eks_subnet_ids" {
  description = "The private subnet ids in the VPC"
  value       = [aws_subnet.private_1.id, aws_subnet.private_2.id]
}

output "vpc" {
  description = "The vpc created by this module to be used for the given region/env combo"
  value       = aws_vpc.primary
}
