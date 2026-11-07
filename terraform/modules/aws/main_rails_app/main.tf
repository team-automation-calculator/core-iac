locals {
  www_redirect_name = "www.${var.automation_calculator_app_host}"
}

# Ordering handle for the Helm release only. A depends_on inside a module
# cannot name resources outside it, so the caller passes the add-on Helm
# release names in through var.addons_dependency and the release waits on this
# resource instead. Do not express this as a module-level depends_on in the
# caller: that defers data.aws_route53_zone to apply time whenever the add-ons
# have pending changes, zone_id becomes unknown, and the ACM validation records
# (zone_id is force-new) are planned for replacement on every add-ons change.
# The RDS, ACM and Route 53 resources here do not need the add-ons at all.
resource "terraform_data" "cluster_addons" {
  input = var.addons_dependency
}

resource "helm_release" "automation-calculator" {
  atomic           = true
  name             = "automation-calculator"
  namespace        = "automation-calculator"
  chart            = var.automation_calculator_helm_release_local_path
  create_namespace = true
  depends_on       = [terraform_data.cluster_addons]
  version          = "0.1.0"

  # Image tag, short commit hash, host and ALB name come from the chart's
  # values-<env>.yaml in git (single source of truth, shared with ArgoCD later).
  # Terraform only injects what must not live in this public repo: the ACM
  # certificate ARN and, below, the secrets.
  values = [
    file("${var.automation_calculator_helm_release_local_path}/values-${var.environment_name}.yaml"),
    templatefile("${path.module}/values.yml", {
      cert_arn = tostring(aws_acm_certificate.automation_calculator_app.arn)
    })
  ]

  set_sensitive = [
    {
      name  = "secrets.databaseUrl"
      value = "postgres://${aws_db_instance.automation_calculator_app.username}:${random_password.database_master_user_password.result}@${aws_db_instance.automation_calculator_app.endpoint}/${aws_db_instance.automation_calculator_app.db_name}"
    },
    {
      name  = "secrets.githubOAuthAppId"
      value = var.github_oauth_app_id
    },
    {
      name  = "secrets.githubOAuthAppSecret"
      value = var.github_oauth_app_secret
    },
    {
      name  = "secrets.googleOAuthAppId"
      value = var.google_oauth_app_id
    },
    {
      name  = "secrets.googleOAuthAppSecret"
      value = var.google_oauth_app_secret
    },
    {
      name  = "secrets.secretKeyBase"
      value = random_password.rails_app_secret_key_base.result
    },
  ]
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
  backup_retention_period     = var.backup_retention_period
  db_name                     = "automation_calculator_app"
  db_subnet_group_name        = aws_db_subnet_group.db_access_subnet_group.name
  engine                      = "postgres"
  engine_version              = var.db_engine_version
  final_snapshot_identifier   = var.skip_final_snapshot ? null : coalesce(var.final_snapshot_identifier, "automation-calculator-${var.environment_name}-final")
  instance_class              = var.db_instance_class
  max_allocated_storage       = 64
  password                    = random_password.database_master_user_password.result
  port                        = var.db_port
  skip_final_snapshot         = var.skip_final_snapshot
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

