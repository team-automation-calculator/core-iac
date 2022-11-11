locals {
  cidr_blocks = {
    "production" = cidrsubnet("10.0.0.0/14", 2, 0)
    "staging"    = cidrsubnet("10.0.0.0/14", 2, 1)
    "dev"        = cidrsubnet("10.0.0.0/14", 2, 2)
  }
}

resource "aws_vpc" "primary" {
  cidr_block = local.cidr_blocks[var.environment_name]

  tags = {
    Project     = "automation-calculator",
    Environment = "dev",
    SourceRepo  = "https://github.com/team-automation-calculator/core-iac"
  }
}

resource "aws_subnet" "public_1a" {
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(aws_vpc.primary.cidr_block, 2, 0)
  availability_zone = "${var.availability_zone}a"
}

resource "aws_subnet" "public_1b" {
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(aws_vpc.primary.cidr_block, 2, 1)
  availability_zone = "${var.availability_zone}b"
}
