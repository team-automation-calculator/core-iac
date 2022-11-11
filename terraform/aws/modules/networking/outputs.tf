output "eks_subnet_ids" {
  description = "The subnet ids in the VPC given to EKS"
  value = [aws_subnet.main_1a.id, aws_subnet.main_1b.id]
}

output "vpc" {
  description = "The vpc created by this module to be used for the given region/env combo"
  value = aws_vpc.primary
}
