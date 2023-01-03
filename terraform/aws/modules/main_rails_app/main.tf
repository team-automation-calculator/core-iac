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
  length  = 24
  special = true
}

resource "aws_route53_zone" "ac_app_domain" {
  name = var.app_domain_name
}

resource "aws_route53_record" "app" {
  name    = aws_route53_zone.ac_app_domain.name
  type    = "A"
  zone_id = aws_route53_zone.ac_app_domain.zone_id
  alias {
    evaluate_target_health = false
    name                   = "automation-calculations.io"
    zone_id                = aws_route53_zone.ac_app_domain.zone_id
  }
}
