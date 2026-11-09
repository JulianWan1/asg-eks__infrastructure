# These outputs are what later steps (security groups, ALB, ASG, RDS) will
# reference. They're also what `terraform output` shows you after apply,
# which is handy for sanity-checking in the console.

output "vpc_id" {
  description = "VPC ID — every resource from here on references this"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs — the ALB uses these"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — EC2 and RDS live here"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "NAT gateway ID — the cost clock to watch"
  value       = aws_nat_gateway.main.id
}
