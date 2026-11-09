# ===========================================================================
# EKS — Kubernetes on the foundation VPC
# ===========================================================================
# Uses the community EKS module (terraform-aws-modules/eks/aws), which wires
# up ~15 IAM roles, policies, and security groups you'd otherwise write by
# hand. It's what most real teams use, and "I used the standard community
# module" is the credible answer when someone asks how you set this up.
#
# What the module creates behind the scenes:
#   - IAM role for the control plane (so AWS can manage the cluster)
#   - IAM role for the worker nodes (so they can join the cluster + pull ECR)
#   - Security group for the cluster (control plane ↔ node communication)
#   - Security group for the nodes (node ↔ node + node ↔ control plane)
#   - EKS cluster (the managed control plane — the "building manager")
#   - Managed node group (an ASG under the hood, but Kubernetes drives it)
#   - OIDC provider (for pod-level IAM later — you can ignore this for now)


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project}-cluster"
  cluster_version = "1.36"

  # --- networking -----------------------------------------------------------
  # Reuse the foundation's VPC and private subnets. Nodes launch here, same
  # as the ASG instances did.
  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # --- access ---------------------------------------------------------------
  # Makes the Kubernetes API reachable from your Mac so `kubectl` works.
  # In production you'd lock this down to a VPN or use a private endpoint.
  cluster_endpoint_public_access = true

  # Grants your IAM user (the one running Terraform) admin access to the
  # cluster. Without this you'd create a cluster you can't talk to.
  enable_cluster_creator_admin_permissions = true

  # --- managed node group ---------------------------------------------------
  # This is the EKS equivalent of the ASG + launch template.
  # The module creates the underlying ASG, launch template, and IAM role
  # for you. You just describe what you want.
  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]   # ~11 pod IPs — enough for your workload

      min_size     = 2    # one node per AZ, same spread as the old ASG
      max_size     = 4    # room for the HPA test in step 2d
      desired_size = 2    # start with the minimum
    }
  }

  tags = {
    Name    = "${var.project}-cluster"
    Project = var.project
  }
}


# ===========================================================================
# Security group rule — let EKS nodes reach RDS
# ===========================================================================
# Same SG-to-SG pattern as the foundation's db_from_app rule. The source is
# now the EKS node security group (created by the module above) instead of
# the hand-made app SG.
#
# This rule lives HERE, not in the foundation, because it references the EKS
# node SG which only exists when EKS is running. When you destroy the eks/
# layer, this rule disappears too — which is correct.

resource "aws_vpc_security_group_ingress_rule" "db_from_eks_nodes" {
  security_group_id            = local.db_sg_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
  description                  = "Postgres from EKS nodes"
}


# ===========================================================================
# Outputs
# ===========================================================================

output "cluster_name" {
  description = "EKS cluster name — used for kubectl setup"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  description = "Security group attached to EKS worker nodes"
  value       = module.eks.node_security_group_id
}
