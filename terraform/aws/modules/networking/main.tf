locals {
  env_vpc_cidr_blocks = {
    "production" = cidrsubnet("10.0.0.0/14", 2, 0)
    "staging"    = cidrsubnet("10.0.1.0/14", 2, 1)
    "dev"        = cidrsubnet("10.0.2.0/14", 2, 2)
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.primary.id
}

resource "aws_eip" "eip_for_nat" {
  vpc        = true
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.eip_for_nat.id
  subnet_id     = aws_subnet.public_1.id
  depends_on    = [aws_internet_gateway.igw]
}

# Adding outbound communication via igw
resource "aws_route_table_association" "vpc_to_igw" {
  gateway_id     = aws_internet_gateway.igw.id
  route_table_id = aws_vpc.primary.main_route_table_id
}

resource "aws_vpc" "primary" {
  cidr_block = local.env_vpc_cidr_blocks[var.environment_name]

  enable_dns_hostnames = true
}

resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(aws_vpc.primary.cidr_block, 2, 0)
  availability_zone = var.availability_zones[0]
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(aws_vpc.primary.cidr_block, 2, 1)
  availability_zone = var.availability_zones[1]
}

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(aws_vpc.primary.cidr_block, 2, 2)
  availability_zone = var.availability_zones[0]
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(aws_vpc.primary.cidr_block, 2, 3)
  availability_zone = var.availability_zones[1]
}
