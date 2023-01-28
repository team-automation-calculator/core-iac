locals {
  www_redirect_name = "www.${var.automation_calculator_app_host}"
}

data "template_file" "automation_calculator_helm_chart_values" {
  template = file("${path.module}/values.yml")
  vars = {
    automation_calculator_app_host = var.automation_calculator_app_host
    alb_name                       = "ac-app-${var.environment_name}"
    cert_arn                       = tostring(aws_acm_certificate.automation_calculator_app.arn)
  }
}

resource "helm_release" "automation-calculator" {
  atomic           = false
  name             = "automation-calculator"
  namespace        = "automation-calculator"
  chart            = var.automation_calculator_helm_release_local_path
  create_namespace = true
  version          = "0.1.0"

  values = [
    data.template_file.automation_calculator_helm_chart_values.rendered
  ]

  set_sensitive {
    name  = "secrets.secretKeyBase"
    value = random_password.rails_app_secret_key_base.result
  }

  set_sensitive {
    name  = "secrets.databaseUrl"
    value = "postgres://${aws_db_instance.automation_calculator_app.username}:${random_password.database_master_user_password.result}@${aws_db_instance.automation_calculator_app.endpoint}/${aws_db_instance.automation_calculator_app.db_name}"
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
  name       = "automation-calculator-db-access-subnet-group-${var.environment_name}"
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
  domain_name = var.automation_calculator_app_host
  subject_alternative_names = [
    local.www_redirect_name
  ]
  validation_method = "DNS"
}

data "aws_route53_zone" "automation_calculator_app" {
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "automation_calculator_app_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.automation_calculator_app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.automation_calculator_app.zone_id
}

resource "aws_route53_record" "automation_calculator_app_www_redirector" {  
  alias {
    name = data.aws_route53_zone.automation_calculator_app.name
    zone_id = data.aws_route53_zone.automation_calculator_app.zone_id
    evaluate_target_health = false
  }
  name    = local.www_redirect_name
  records = [var.automation_calculator_app_host]
  type    = "A"
  zone_id = data.aws_route53_zone.automation_calculator_app.zone_id
}
