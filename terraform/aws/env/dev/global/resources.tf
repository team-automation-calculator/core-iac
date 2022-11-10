module "automation-calculator-infra" {
  source = "../../../modules/main-rails-app"
  environment_name = "dev"
  cidr_block = 10.0.0.0/24
}
