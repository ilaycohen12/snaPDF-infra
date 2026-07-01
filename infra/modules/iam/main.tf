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
  name = "${var.cluster_name}-alb-controller"  # e.g. "snapdf-dev-alb-controller"

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

# Policy — full official permissions the ALB controller needs to manage AWS load balancers
resource "aws_iam_policy" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "tag:GetResources",
          "tag:TagResources"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule"
        ]
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
  name = "${var.cluster_name}-eso"  # e.g. "snapdf-dev-eso"

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

# ── KEDA ─────────────────────────────────────────────────────────────────────
# KEDA needs to read queue depth to decide how many worker pods to scale to

resource "aws_iam_role" "keda" {
  name = "${var.cluster_name}-keda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:keda:keda-operator" # locked to KEDA operator service account
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_iam_policy" "keda" {
  name = "${var.cluster_name}-keda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes"] # read queue depth — the only thing KEDA needs
      Resource = [var.signed_queue_arn]      # only the signed queue — KEDA only watches this one
    }]
  })
}

resource "aws_iam_role_policy_attachment" "keda" {
  policy_arn = aws_iam_policy.keda.arn
  role       = aws_iam_role.keda.name
}

# ── PDF Worker ────────────────────────────────────────────────────────────────
# Both signed and free workers share one IAM role — same permissions, different queue URLs via env vars

resource "aws_iam_role" "worker" {
  name = "${var.cluster_name}-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
        # Wildcard covers both worker deployments (free-worker-*, signed-worker-*) in dev/staging.
        # api/auth service accounts are listed explicitly since they don't match the *-worker-* pattern
        # but share this same role (Bug 19 fix).
        StringLike = {
          "${local.oidc_url}:sub" = [
            "system:serviceaccount:dev:*-worker-*",
            "system:serviceaccount:staging:*-worker-*",
            "system:serviceaccount:dev:auth-dev-sa",
            "system:serviceaccount:staging:auth-staging-sa",
            "system:serviceaccount:dev:api-dev-sa",
            "system:serviceaccount:staging:api-staging-sa"
          ]
        }
      }
    }]
  })

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_iam_policy" "worker" {
  name = "${var.cluster_name}-worker"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",       # send a job message to the queue (API)
          "sqs:ReceiveMessage",    # pick up a message from the queue (worker)
          "sqs:DeleteMessage",     # delete it after processing (worker)
          "sqs:GetQueueAttributes" # read queue metadata
        ]
        Resource = [var.signed_queue_arn, var.free_queue_arn] # both queues
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject", # upload the generated PDF
          "s3:GetObject"  # needed to generate presigned download URLs
        ]
        Resource = "${var.bucket_arn}/*" # all objects inside the PDF bucket
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker" {
  policy_arn = aws_iam_policy.worker.arn
  role       = aws_iam_role.worker.name
}
