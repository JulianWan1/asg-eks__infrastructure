# ===========================================================================
# VPC + Networking
# ===========================================================================
# Everything in the project lives inside this VPC. The CIDR block (10.0.0.0/16)
# carves out ~65,000 private IPs that only exist inside your network. Nothing
# from the outside world can see them unless you explicitly set up a gateway.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true   # lets instances resolve DNS names
  enable_dns_hostnames = true   # gives instances DNS names when they have public IPs

  tags = { Name = "${var.project}-vpc" }
}

# Look up which availability zones exist in our region.
# ap-southeast-1 has 3 (a, b, c). We use the first two.
data "aws_availability_zones" "available" {
  state = "available"
}

# Explicit CIDRs — easier to reason about than computed ones.
#   Public:  10.0.1.0/24, 10.0.2.0/24     (ALB)
#   Private: 10.0.10.0/24, 10.0.11.0/24   (EC2 + RDS)
# The gap in numbering (1-2 vs 10-11) is intentional — leaves room if you ever
# need to add more subnet tiers without reshuffling.
locals {
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
}


# ===========================================================================
# Public subnets — where the ALB lives
# ===========================================================================
# "Public" means two things:
#   1. The route table sends 0.0.0.0/0 to the internet gateway
#   2. Instances can get public IPs
# We need at least 2 in different AZs — AWS enforces this for an ALB.

resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name                                                = "${var.project}-public-${count.index + 1}"
    # Kubernetes tags — the AWS Load Balancer Controller reads these to know
    # where to place internet-facing ALBs. Harmless when running ASG instead.
    "kubernetes.io/role/elb"                            = "1"
    "kubernetes.io/cluster/${var.project}-cluster"      = "shared"
  }
}


# ===========================================================================
# Private subnets — where EC2 instances and RDS live
# ===========================================================================
# "Private" = no direct inbound path from the internet. Instances here can
# still reach OUT (pull Docker images, call AWS APIs) via the NAT gateway,
# but nobody from outside can initiate a connection to them.
#
# Two AZs again — RDS needs subnets in at least 2 AZs for its subnet group,
# and spreading EC2 across AZs is basic availability hygiene.

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                                = "${var.project}-private-${count.index + 1}"
    # Kubernetes tags — tells the Load Balancer Controller where to place
    # internal ALBs. Harmless when running ASG instead.
    "kubernetes.io/role/internal-elb"                   = "1"
    "kubernetes.io/cluster/${var.project}-cluster"      = "shared"
  }
}


# ===========================================================================
# Internet Gateway — the front door
# ===========================================================================
# Without this, nothing in the VPC can talk to the internet. You attach it to
# the VPC, then point the public route table at it.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw" }
}


# ===========================================================================
# NAT Gateway — the one-way door for private subnets
# ===========================================================================
# Private instances need to reach the internet (pull images from ECR, download
# packages) but should never be reachable FROM the internet. The NAT gateway
# handles this: outbound yes, inbound no.
#
# It needs:
#   - An Elastic IP (a static public address)
#   - To sit in a PUBLIC subnet (it's the bridge between private and public)
#
# COST NOTE: ~$0.045/hr ≈ $32/month if running 24/7. This is the #1 reason
# `make down` exists — destroy it after each session, recreate on `make up`.
# One NAT (not one per AZ) keeps costs down. Fine for a learning lab; in
# production you'd run one per AZ for availability.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # lives in the first public subnet

  tags = { Name = "${var.project}-nat" }

  # The IGW must exist before the NAT, because the NAT needs a working
  # internet path in the public subnet to function.
  depends_on = [aws_internet_gateway.main]
}


# ===========================================================================
# Route tables — the road signs
# ===========================================================================
# Every subnet is associated with a route table. The key line is the
# 0.0.0.0/0 rule: "for anything NOT inside the VPC, send it HERE."
#
# Traffic between subnets inside the VPC routes automatically (the "local"
# route). These rules only control how traffic leaves the VPC.

# --- Public: outside traffic → internet gateway (direct two-way) -----------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private: outside traffic → NAT gateway (one-way out only) -------------
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
