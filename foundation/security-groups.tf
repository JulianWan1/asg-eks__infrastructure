# ===========================================================================
# Security groups — who can talk to whom
# ===========================================================================
# Three groups forming a chain: internet → ALB → app → database.
# Everything not explicitly allowed is denied by default.
#
# The critical pattern: rules reference other security groups by ID, not by
# IP address. This is what makes security groups work with auto-scaling —
# when a new EC2 instance joins the "app" SG, it's automatically allowed to
# talk to the "db" SG without anyone updating an IP whitelist.
#
# We use standalone rule resources (aws_vpc_security_group_*_rule) instead
# of inline blocks — this is the recommended pattern in AWS provider 5.x
# and avoids rule conflicts when you add more rules later.


# ===========================================================================
# ALB security group — the only thing facing the internet
# ===========================================================================
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Allow HTTP/HTTPS from the internet to the ALB"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-alb-sg" }
}

# Inbound: HTTP from anywhere
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP from internet"
}

# Inbound: HTTPS from anywhere (ready for when you add a certificate)
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS from internet"
}

# Outbound: allow all — the ALB needs to reach the app instances and
# perform health checks. Restricting egress here adds complexity with
# no real security gain since the ALB only talks to things you configure.
resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}


# ===========================================================================
# App (EC2) security group — only accepts traffic from the ALB
# ===========================================================================
resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "Allow traffic from ALB to app instances on port 3000"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-app-sg" }
}

# Inbound: port 3000 from the ALB security group ONLY.
# This is the SG-to-SG reference — no IP addresses. Any resource in the
# ALB SG can reach port 3000 on any resource in this SG, and nothing else can.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "App port from ALB only"
}

# Outbound: allow all — instances need to reach RDS (port 5432),
# ECR (to pull Docker images via the NAT), and AWS APIs.
resource "aws_vpc_security_group_egress_rule" "app_all_out" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound (RDS, ECR pulls, AWS APIs)"
}


# ===========================================================================
# Database (RDS) security group — only accepts connections from app instances
# ===========================================================================
resource "aws_security_group" "db" {
  name        = "${var.project}-db-sg"
  description = "Allow Postgres from app instances only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-db-sg" }
}

# Inbound: Postgres from the app security group ONLY.
# The database is invisible to everything except your EC2 instances.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Postgres from app instances only"
}

# Outbound: allow all — RDS occasionally needs to reach AWS services
# for patches, logs, and monitoring.
resource "aws_vpc_security_group_egress_rule" "db_all_out" {
  security_group_id = aws_security_group.db.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}


# ===========================================================================
# Outputs — later steps reference these when assigning SGs to resources
# ===========================================================================
output "alb_sg_id" {
  description = "ALB security group ID — used when creating the ALB"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "App security group ID — used in the launch template"
  value       = aws_security_group.app.id
}

output "db_sg_id" {
  description = "Database security group ID — used when creating RDS"
  value       = aws_security_group.db.id
}
