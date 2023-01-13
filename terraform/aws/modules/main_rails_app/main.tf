resource "helm_release" "automation-calculator" {
  atomic           = false
  name             = "automation-calculator"
  namespace        = "automation-calculator"
  chart            = var.automation_calculator_helm_release_local_path
  create_namespace = true
  version          = "0.1.0"

  set {
    name  = "railsEnv"
    value = "production"
  }

  set {
    name  = "logToStdout"
    value = "true"
  }

  set_sensitive {
    name  = "secrets.secretKeyBase"
    value = random_password.rails_app_secret_key_base.result
  }

  set_sensitive {
    name  = "secrets.databaseUrl"
    value = "postgres://${aws_db_instance.automation_calculator_app.username}:${random_password.database_master_user_password.result}@${aws_db_instance.automation_calculator_app.endpoint}/${aws_db_instance.automation_calculator_app.db_name}"
  }

  set {
    name  = "ingress.host"
    value = var.automation_calculator_app_host
  }
}

resource "aws_security_group" "allow_db_access_from_eks" {
  name        = "allow_db_access_from_eks"
  description = "Allow DB Access from EKS"

  ingress {
    description     = "Allow DB Access from EKS"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = var.db_security_group_ids
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "Automation Calculator DB Access"
  }

  vpc_id = var.vpc_id
}

resource "aws_db_subnet_group" "db_access_subnet_group" {
  name       = "automation-calculator-db-access-subnet-group"
  subnet_ids = var.db_subnet_group_ids
}

resource "aws_db_instance" "automation_calculator_app" {
  allocated_storage           = 10
  apply_immediately           = true
  allow_major_version_upgrade = true
  auto_minor_version_upgrade  = true
  db_name                     = "automation_calculator_app"
  db_subnet_group_name        = aws_db_subnet_group.db_access_subnet_group.name
  engine                      = "postgres"
  instance_class              = var.db_instance_class
  max_allocated_storage       = 64
  password                    = random_password.database_master_user_password.result
  port                        = var.db_port
  skip_final_snapshot         = true
  username                    = "automation_calculator_devops"
  vpc_security_group_ids = [
    aws_security_group.allow_db_access_from_eks.id,
  ]
}

resource "random_password" "database_master_user_password" {
  length  = 32
  special = false
}

resource "random_password" "rails_app_secret_key_base" {
  length  = 128
  special = false
  upper   = false
}

resource "aws_acm_certificate" "automation_calculator_app" {
  domain_name       = var.automation_calculator_app_host
  validation_method = "DNS"
}
