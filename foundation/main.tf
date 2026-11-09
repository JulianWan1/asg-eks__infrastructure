# Foundation — shared networking, database, and registry.
# Both compute layers (asg/ and eks/) read this state via terraform_remote_state.
# State lives in the same S3 bucket as Phase 0, under its own key.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "asg-eks-devops-lab-bucket"
    key            = "foundation/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "asg-eks-devops-lab-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
