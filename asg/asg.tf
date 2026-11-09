# ===========================================================================
# ASG — the auto-scaling compute layer
# ===========================================================================
# Four pieces:
#   1. IAM role + instance profile — gives EC2 permission to pull from ECR
#   2. Launch template — "what does each instance look like?"
#   3. Auto Scaling Group — "how many, where, and register them with the ALB"
#   4. Scaling policy — "when do we add or remove instances?"


# ===========================================================================
# Data source — latest Amazon Linux 2023 AMI
# ===========================================================================
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}


# ===========================================================================
# IAM role — what the EC2 instances are allowed to do
# ===========================================================================
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project}-ec2-role" }
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}


# ===========================================================================
# Launch template — blueprint for every instance the ASG creates
# ===========================================================================
resource "aws_launch_template" "app" {
  name          = "${var.project}-app-lt"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [local.app_sg_id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = base64encode(<<-USERDATA
#!/bin/bash
set -euo pipefail

# Install and start Docker
dnf install -y docker
systemctl enable --now docker

# Authenticate to ECR using the instance's IAM role
aws ecr get-login-password --region ${var.aws_region} \
  | docker login --username AWS --password-stdin ${local.ecr_repository_url}

# Pull and run the app container
docker run -d \
  --name url-shortener \
  -p 3000:3000 \
  -e DATABASE_URL='${local.database_url}' \
  -e PORT=3000 \
  -e LOG_LEVEL=info \
  --restart unless-stopped \
  ${local.ecr_repository_url}:latest
USERDATA
  )

  tags = { Name = "${var.project}-app-lt" }
}


# ===========================================================================
# Auto Scaling Group
# ===========================================================================
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-asg"
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = local.private_subnet_ids

  target_group_arns = [aws_lb_target_group.app.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "asg"
    propagate_at_launch = true
  }
}


# ===========================================================================
# Scaling policy — target-tracking on CPU
# ===========================================================================
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${var.project}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 40.0
  }
}


# ===========================================================================
# Outputs
# ===========================================================================
output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.app.id
}
