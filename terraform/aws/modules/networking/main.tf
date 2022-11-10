resource "aws_vpc" "primary" {
  cidr_block = var.cidr_block

  tags = {
    Project = "automation-calculator",
    Environment = "dev"
    SourceRepo = "https://github.com/team-automation-calculator/core-iac"
  }
}

resource "aws_subnet" "main_1a" {
  vpc_id = aws_vpc.primary.id
  cidr_block = "10.213.0.0/24"
  availability_zone = "us-west-1a"
}

resource "aws_subnet" "main_1c" {
  vpc_id = aws_vpc.primary.id
  cidr_block = var.environment_name
  availability_zone = "us-west-1c"
}