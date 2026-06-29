# ── GitHub Actions OIDC Provider ─────────────────────────────────────────────
# Allows GitHub Actions to authenticate to AWS without hardcoded access keys.
# GitHub presents a signed JWT token; AWS verifies it against this OIDC provider.

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # GitHub's OIDC cert thumbprint
}

# ── GitHub Actions CI Role ────────────────────────────────────────────────────
# This role is assumed by GitHub Actions during CI runs.
# Trust is locked to the snaPDF repo on the main branch only.

resource "aws_iam_role" "github_actions_ci" {
  name = "github-actions-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:ilaycohen12/snaPDF:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = { Project = "snapdf", ManagedBy = "terragrunt" }
}

# Policy — CI needs to push images to ECR and restart deployments on EKS
resource "aws_iam_policy" "github_actions_ci" {
  name = "github-actions-ci"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"                # authenticate docker to ECR
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",                            # push image layers and tag
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = [
          "arn:aws:ecr:us-east-1:086241318869:repository/snapdf-api",
          "arn:aws:ecr:us-east-1:086241318869:repository/snapdf-worker",
          "arn:aws:ecr:us-east-1:086241318869:repository/snapdf-auth"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]           # needed for update-kubeconfig
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ci" {
  policy_arn = aws_iam_policy.github_actions_ci.arn
  role       = aws_iam_role.github_actions_ci.name
}

# ── ECR Repository ───────────────────────────────────────────────────────────
# One registry shared by both dev and prod clusters
# NOTE: already created manually in Phase 0 — import with:
#   terragrunt import aws_ecr_repository.app snapdf-app

resource "aws_ecr_repository" "api" {
  name                 = "snapdf-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
  tags = { Project = "snapdf", ManagedBy = "terragrunt" }
}

resource "aws_ecr_repository" "worker" {
  name                 = "snapdf-worker"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
  tags = { Project = "snapdf", ManagedBy = "terragrunt" }
}

resource "aws_ecr_repository" "auth" {
  name                 = "snapdf-auth"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
  tags = { Project = "snapdf", ManagedBy = "terragrunt" }
}

# ── API Key Secret ────────────────────────────────────────────────────────────
# Creates the slot in Secrets Manager — value is set manually after apply:
#   aws secretsmanager put-secret-value \
#     --secret-id snapdf/api-key \
#     --secret-string "your-actual-api-key-here"

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "snapdf/api-key"
  description             = "API key for signed users — checked by the Flask web server via X-API-Key header"
  recovery_window_in_days = 0 # allows immediate deletion with terraform destroy (default is 30 day wait)

  tags = {
    Project   = "snapdf"
    ManagedBy = "terragrunt"
  }
}
