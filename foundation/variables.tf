variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Name prefix for all resources (keeps things findable in the console)"
  type        = string
  default     = "asg-eks-devops-lab"
}

variable "vpc_cidr" {
  description = "CIDR block for the whole VPC — 10.0.0.0/16 gives ~65k IPs"
  type        = string
  default     = "10.0.0.0/16"
}
