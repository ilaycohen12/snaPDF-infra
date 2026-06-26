# ── Data source: get the AWS account ID at runtime ──────────────────────────
data "aws_caller_identity" "current" {}

# ── Local: strip the ARN prefix to get the plain OIDC URL ───────────────────
# e.g. arn:aws:iam::123:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXX
#   →  oidc.eks.us-east-1.amazonaws.com/id/XXX
locals {
  oidc_url = replace(
    var.oidc_provider_arn,
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/",
    ""
  )
}

# ── ALB Ingress Controller ───────────────────────────────────────────────────

# Role — trusts only the alb-controller service account in kube-system namespace
resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"  # e.g. "projectview-dev-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }  # trusts this cluster's OIDC provider
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"  # locked to this exact service account
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

# Policy — permissions the ALB controller needs to manage AWS load balancers
resource "aws_iam_policy" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:Describe*"]                          # read VPCs, subnets, security groups
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:*"]                 # create and manage ALBs and target groups
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]            # needed to create the ELB service-linked role on first run
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["acm:DescribeCertificate", "acm:ListCertificates"]  # needed for HTTPS listeners
        Resource = "*"
      }
    ]
  })
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "alb_controller" {
  policy_arn = aws_iam_policy.alb_controller.arn  # the policy above
  role       = aws_iam_role.alb_controller.name   # the role above
}

# ── External Secrets Operator ────────────────────────────────────────────────

# Role — trusts only the external-secrets service account in external-secrets namespace
resource "aws_iam_role" "eso" {
  name = "${var.cluster_name}-eso"  # e.g. "projectview-dev-eso"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }  # trusts this cluster's OIDC provider
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:external-secrets:external-secrets"  # locked to ESO service account
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

# Policy — ESO only needs to read secrets, nothing else
resource "aws_iam_policy" "eso" {
  name = "${var.cluster_name}-eso"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",   # read the secret value
        "secretsmanager:DescribeSecret"    # read secret metadata (name, ARN, tags)
      ]
      Resource = "*"  # all secrets in this account — can be scoped to specific ARNs later
    }]
  })
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "eso" {
  policy_arn = aws_iam_policy.eso.arn  # the policy above
  role       = aws_iam_role.eso.name   # the role above
}
