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

resource "aws_db_instance" "automation_calculator_app" {
  allocated_storage           = 10
  apply_immediately           = true
  allow_major_version_upgrade = true
  auto_minor_version_upgrade  = true
  db_name                     = "automation_calculator_app"
  engine                      = "postgres"
  instance_class              = var.database_instance_class
  max_allocated_storage       = 64
  password                    = random_password.database_master_user_password.result
  skip_final_snapshot         = true
  username                    = "automation_calculator_devops"
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

resource "aws_route53_zone" "ac_app_domain" {
  name = var.environment_name == "production" ? var.app_domain_name : "${var.environment_name}.${var.app_domain_name}"
}
