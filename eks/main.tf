# EKS compute layer — Kubernetes cluster + managed node group.
# Reads networking, security groups, RDS, and ECR from the foundation state.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "asg-eks-devops-lab-bucket"
    key            = "eks/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "asg-eks-devops-lab-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "asg-eks-devops-lab"
}


# ===========================================================================
# Remote state — read foundation outputs
# ===========================================================================

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = "asg-eks-devops-lab-bucket"
    key    = "foundation/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.foundation.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  db_sg_id           = data.terraform_remote_state.foundation.outputs.db_sg_id
}
