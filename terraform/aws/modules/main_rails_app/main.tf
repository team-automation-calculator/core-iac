# Create IAM role for EKS
resource "aws_iam_role" "eks_iam_role" {
  name = "automation_calculator_eks_iam_role_${var.environment_name}"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_iam_role.name
}

resource "aws_eks_cluster" "eks_cluster" {
  name     = "automation_calculator_eks_cluster_${var.environment_name}"
  role_arn = aws_iam_role.eks_iam_role.arn

  vpc_config {
    subnet_ids = var.eks_subnet_ids
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

resource "aws_db_instance" "automation_calculator_app" {
  allocated_storage           = 10
  apply_immediately           = true
  allow_major_version_upgrade = true
  auto_minor_version_upgrade  = true
  db_name                     = "automation_calculator_app"
  engine                      = "postgresql"
  instance_class              = var.database_instance_class
  max_allocated_storage       = 64
  password                    = random_password.database_master_user_password.result
  skip_final_snapshot         = true
  username                    = "automation_calculator_devops"
}

resource "random_password" "database_master_user_password" {
  length  = 24
  special = true
}
