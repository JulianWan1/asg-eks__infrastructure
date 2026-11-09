# ===========================================================================
# AWS Load Balancer Controller — IAM (IRSA)
# ===========================================================================
# The controller pod needs permission to create/update ALBs, target groups,
# and security groups on your behalf. IRSA (IAM Roles for Service Accounts)
# lets a specific Kubernetes service account assume an IAM role — no static
# credentials needed, no secrets to rotate.
#
# How it works:
#   1. EKS cluster has an OIDC provider (the module created it)
#   2. We create an IAM role whose trust policy says:
#      "only the controller's service account in the kube-system namespace
#       can assume this role"
#   3. Helm annotates the service account with the role ARN
#   4. EKS exchanges the pod's OIDC token for temporary AWS credentials

# Fetch the official IAM policy document from the LBC GitHub repo.
# ~200 lines covering exactly the permissions the controller needs.
data "http" "lbc_policy_doc" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.project}-lbc-policy"
  policy = data.http.lbc_policy_doc.response_body
}

# Trust policy — who is allowed to assume this role?
# Answer: only the aws-load-balancer-controller service account in kube-system.
# If the namespace or name doesn't match exactly, credential injection is denied.
data "aws_iam_policy_document" "lbc_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project}-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_trust.json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}