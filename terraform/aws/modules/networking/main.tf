locals {
  env_vpc_cidr_blocks = {
    "production"  = cidrsubnet("10.0.0.0/14", 2, 0)
    "staging"     = cidrsubnet("10.0.1.0/14", 2, 1)
    "development" = cidrsubnet("10.0.2.0/14", 2, 2)
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

# Adding outbound comms via route
resource "aws_route" "outbound_to_internet_route" {
  route_table_id         = aws_vpc.primary.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_vpc" "primary" {
  cidr_block           = local.env_vpc_cidr_blocks[var.environment_name]
  enable_dns_hostnames = true
}

resource "aws_subnet" "public_1" {
  availability_zone       = var.availability_zones[0]
  cidr_block              = cidrsubnet(aws_vpc.primary.cidr_block, 2, 0)
  map_public_ip_on_launch = true
  tags = {
    "kubernetes.io/role/elb" = "1",
    Name                     = "public_1"
  }
  vpc_id = aws_vpc.primary.id
}

resource "aws_subnet" "public_2" {
  availability_zone       = var.availability_zones[1]
  cidr_block              = cidrsubnet(aws_vpc.primary.cidr_block, 2, 1)
  map_public_ip_on_launch = true
  tags = {
    "kubernetes.io/role/elb" = "1",
    Name                     = "public_2"
  }
  vpc_id = aws_vpc.primary.id
}

resource "aws_route_table" "private_subnets_route_table" {
  vpc_id = aws_vpc.primary.id
  tags = {
    Name = "private_subnets_route_table"
  }
}

resource "aws_route" "outbound_to_internet_via_nat_route" {
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
  route_table_id         = aws_route_table.private_subnets_route_table.id
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_subnets_route_table.id
}

resource "aws_subnet" "private_1" {
  availability_zone       = var.availability_zones[0]
  cidr_block              = cidrsubnet(aws_vpc.primary.cidr_block, 2, 2)
  map_public_ip_on_launch = false
  tags = {
    "kubernetes.io/role/internal-elb" = "1",
    Name                              = "private_1"
  }
  vpc_id = aws_vpc.primary.id
}

resource "aws_subnet" "private_2" {
  availability_zone       = var.availability_zones[1]
  cidr_block              = cidrsubnet(aws_vpc.primary.cidr_block, 2, 3)
  map_public_ip_on_launch = false
  tags = {
    "kubernetes.io/role/internal-elb" = "1",
    Name                              = "private_2"
  }
  vpc_id = aws_vpc.primary.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_subnets_route_table.id
}
