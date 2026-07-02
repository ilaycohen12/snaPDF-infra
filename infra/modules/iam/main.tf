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
      Resource = var.signed_queue_arns      # every signed queue this cluster's namespaces use
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
        # Wildcard covers both worker deployments (free-worker-*, signed-worker-*) in every
        # namespace this cluster hosts. api/auth service accounts are listed explicitly since
        # they don't match the *-worker-* pattern but share this same role (Bug 19 fix).
        # Generated per-namespace via var.app_namespaces so this works identically for the dev
        # cluster (dev + staging) and the prod cluster (production) instead of hardcoding
        # dev/staging regardless of which cluster applies this module (Bug 30 fix).
        StringLike = {
          "${local.oidc_url}:sub" = flatten([
            for ns in var.app_namespaces : [
              "system:serviceaccount:${ns}:*-worker-*",
              "system:serviceaccount:${ns}:auth-${ns}-sa",
              "system:serviceaccount:${ns}:api-${ns}-sa"
            ]
          ])
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
        Resource = concat(var.signed_queue_arns, var.free_queue_arns) # every signed+free queue this cluster's namespaces use
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject", # upload the generated PDF
          "s3:GetObject"  # needed to generate presigned download URLs
        ]
        Resource = [for arn in var.bucket_arns : "${arn}/*"] # all objects inside every PDF bucket this cluster's namespaces use
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker" {
  policy_arn = aws_iam_policy.worker.arn
  role       = aws_iam_role.worker.name
}

# ── Karpenter ─────────────────────────────────────────────────────────────────
# Two roles: one for the Karpenter controller pod (IRSA, calls the EC2 API to
# launch/terminate nodes), one for the actual EC2 instances Karpenter launches
# (the "node role" every Karpenter-provisioned node runs as).

# Controller role — trusts only the karpenter service account
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url}:sub" = "system:serviceaccount:kube-system:karpenter"
          "${local.oidc_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2ReadOnly" # read-only discovery — safe to scope broadly
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeLaunchTemplates"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2NodeLifecycle" # create/tag/terminate the actual nodes Karpenter provisions
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassNodeRoleOnly" # scoped tightly -- PassRole is a privilege-escalation vector if left wildcard
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Sid      = "EKSClusterRead"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "*"
      },
      {
        Sid      = "AMIResolution" # Karpenter looks up current EKS-optimized AMI IDs via SSM public parameters
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "*"
      },
      {
        Sid      = "SpotPricing" # used for On-Demand/Spot price comparison even when only On-Demand is allowed
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}

# Node role — the role every EC2 instance Karpenter launches actually runs as.
# Uses AWS's standard managed policies for EKS worker nodes (same requirements
# any EKS node needs, Karpenter-provisioned or not).
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  policy_arn = each.value
  role       = aws_iam_role.karpenter_node.name
}

# Instance profile — EC2 instances need this wrapper around the role, not the
# bare role itself. Karpenter's EC2NodeClass references this by name.
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}
