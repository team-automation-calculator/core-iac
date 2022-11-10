output "eks_subnet_ids" {
  value = [aws_subnet.main_1a.id, aws_subnet.main_1b.id]
  description = "The subnet ids in the VPC given to EKS"
}
