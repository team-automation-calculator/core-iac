output "eks_subnet_ids" {
  value = [aws_subnet.main_1a, aws_subnet.main_1b]
  description = "The subnets in the VPC given to EKS"
}
