# ===========================================================================
# ALB — the public entry point to the application
# ===========================================================================
# The ALB lives in the public subnets (both AZs) and forwards HTTP traffic
# to healthy app instances in the private subnets. It uses the ALB security
# group from the foundation.
#
# Three pieces work together:
#   1. The ALB itself — accepts traffic from the internet
#   2. The target group — a roster of instances + a health check definition
#   3. The listener — a rule: "port 80 → forward to that target group"


# ===========================================================================
# Application Load Balancer
# ===========================================================================
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [local.alb_sg_id]
  subnets            = local.public_subnet_ids

  tags = { Name = "${var.project}-alb" }
}


# ===========================================================================
# Target group — where instances get registered
# ===========================================================================
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/readyz"
    port                = "3000"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-app-tg" }
}


# ===========================================================================
# Listener — port 80 → target group
# ===========================================================================
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}


# ===========================================================================
# Outputs
# ===========================================================================
output "alb_dns_name" {
  description = "ALB public DNS name — the URL to reach the app"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "Target group ARN — referenced by the ASG"
  value       = aws_lb_target_group.app.arn
}
