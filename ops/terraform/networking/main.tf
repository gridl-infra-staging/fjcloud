# Networking module: VPC, subnets, gateways, route tables, security groups.

locals {
  az_a = "${var.region}a"
  az_b = "${var.region}b"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "fjcloud-${var.env}"
  }
}

# -----------------------------------------------------------------------------
# Public subnets (ALB, NAT gateway)
# -----------------------------------------------------------------------------

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = true

  tags = {
    Name = "fjcloud-${var.env}-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = local.az_b
  map_public_ip_on_launch = true

  tags = {
    Name = "fjcloud-${var.env}-public-b"
  }
}

# -----------------------------------------------------------------------------
# Private subnets (RDS, internal EC2)
# -----------------------------------------------------------------------------

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = local.az_a

  tags = {
    Name = "fjcloud-${var.env}-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = local.az_b

  tags = {
    Name = "fjcloud-${var.env}-private-b"
  }
}

# -----------------------------------------------------------------------------
# Internet gateway (public internet access for public subnets)
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "fjcloud-${var.env}-igw"
  }
}

# -----------------------------------------------------------------------------
# NAT gateway (outbound internet for private subnets — single NAT for MVP)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "fjcloud-${var.env}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "fjcloud-${var.env}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Route tables
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "fjcloud-${var.env}-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "fjcloud-${var.env}-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Security groups
# -----------------------------------------------------------------------------

# ALB: accepts HTTP/HTTPS from internet, forwards to API on 3001
resource "aws_security_group" "alb" {
  name        = "fjcloud-${var.env}-sg-alb"
  description = "ALB: inbound 80+443 from internet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "fjcloud-${var.env}-sg-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
}

# API: accepts traffic from ALB, self-referencing for internal calls, outbound all
resource "aws_security_group" "api" {
  name        = "fjcloud-${var.env}-sg-api"
  description = "API server: inbound from ALB on 3001, self-ref, outbound all"
  vpc_id      = aws_vpc.main.id

  # AWS forces replacement when the security-group description changes, but the
  # current staging drift is metadata-only and the live rules already enforce
  # port 3001. Ignore description drift so the domain cutover does not churn
  # the attached instance security group.
  lifecycle {
    ignore_changes = [description]
  }

  tags = {
    Name = "fjcloud-${var.env}-sg-api"
  }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "api_self" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_outbound" {
  security_group_id = aws_security_group.api.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# RDS: only reachable from API security group on 5432
resource "aws_security_group" "rds" {
  name        = "fjcloud-${var.env}-sg-rds"
  description = "RDS: inbound 5432 from API SG only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "fjcloud-${var.env}-sg-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_api" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# Flapjack VMs: inbound 7700 from API SG only, outbound all
resource "aws_security_group" "flapjack_vm" {
  name        = "fjcloud-${var.env}-sg-flapjack-vm"
  description = "Flapjack VM: inbound 7700 from API SG, outbound all"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "fjcloud-${var.env}-sg-flapjack-vm"
  }
}

resource "aws_vpc_security_group_ingress_rule" "flapjack_from_api" {
  security_group_id            = aws_security_group.flapjack_vm.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 7700
  to_port                      = 7700
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "flapjack_outbound" {
  security_group_id = aws_security_group.flapjack_vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
