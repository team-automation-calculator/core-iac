module "automation-calculator-infra" {
  source = "../../../modules/main-rails-app"
  environment_name = "dev"
  cidr_block = 10.213.1.0/24
}
