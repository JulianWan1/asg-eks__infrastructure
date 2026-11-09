# ===========================================================================
# ECR — where the Docker image lives
# ===========================================================================
# ECR is a private Docker registry in your AWS account. You build the image
# locally (or in CI), push it here, and the EC2 instances pull from it on
# boot via the NAT gateway.
#
# This resource is completely independent of the VPC — it's a global AWS
# service scoped to your account and region. No subnets, no security groups.


resource "aws_ecr_repository" "app" {
  name = "${var.project}-app"

  # MUTABLE lets you overwrite a tag like "latest" with a new image.
  # For a dev lab, this is convenient — push a new build to "latest" and
  # your next EC2 instance picks it up automatically.
  # In production you'd use IMMUTABLE to prevent accidental overwrites
  # and enforce unique tags per build (e.g. git SHA).
  image_tag_mutability = "MUTABLE"

  # force_delete lets `terraform destroy` remove the repo even when it
  # still contains images. Without this, destroy fails if images exist,
  # which blocks your `make down` workflow.
  force_delete = true

  # Basic vulnerability scanning on every push — free, no reason not to.
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}-app" }
}


# ===========================================================================
# Lifecycle policy — auto-clean old images
# ===========================================================================
# Without this, every push accumulates forever and storage costs grow.
# Keep the 5 most recent images, expire the rest. For a lab this is
# mostly hygiene; in production you'd tune the count based on your
# rollback window.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}


# ===========================================================================
# Outputs
# ===========================================================================

# The full URL you use to tag and push images, and that EC2 instances
# use to pull. Looks like:
#   123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/devops-lab-app
output "ecr_repository_url" {
  description = "Full ECR repository URL for docker push/pull"
  value       = aws_ecr_repository.app.repository_url
}
