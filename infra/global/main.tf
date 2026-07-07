# ── GitHub Actions OIDC Provider ─────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ── GitHub Actions CI Role ────────────────────────────────────────────────────
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
          "token.actions.githubusercontent.com:sub" = [
            "repo:ilaycohen12/snaPDF:ref:refs/heads/main",
            "repo:ilaycohen12/snaPDF:ref:refs/heads/staging",
            "repo:ilaycohen12/snaPDF:ref:refs/heads/prod",
          ]
        }
      }
    }]
  })

  tags = { Project = "snapdf", ManagedBy = "terragrunt" }
}

resource "aws_iam_policy" "github_actions_ci" {
  name = "github-actions-ci"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
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
          "ecr:PutImage",
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
        Action   = ["eks:DescribeCluster"]
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
resource "aws_secretsmanager_secret" "api_key" {
  name                    = "snapdf/api-key"
  description             = "API key for signed users — checked by the Flask web server via X-API-Key header"
  recovery_window_in_days = 0

  tags = {
    Project   = "snapdf"
    ManagedBy = "terragrunt"
  }
}

# ── Route53 Hosted Zone ───────────────────────────────────────────────────────
resource "aws_route53_zone" "main" {
  name = "snapdf.bond"

  tags = {
    Project   = "snapdf"
    ManagedBy = "terragrunt"
  }
}

# ── ACM Certificate for TLS ──────────────────────────────────────────────────
resource "aws_acm_certificate" "main" {
  domain_name               = "snapdf.bond"
  subject_alternative_names = ["*.snapdf.bond"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project   = "snapdf"
    ManagedBy = "terragrunt"
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.resource_record_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }...
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value[0].name
  type    = each.value[0].type
  ttl     = 60
  records = [each.value[0].value]
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

# ── ACM Certificate for the dev wildcard subdomain ───────────────────────────
resource "aws_acm_certificate" "dev_wildcard" {
  domain_name               = "dev.snapdf.bond"
  subject_alternative_names = ["*.dev.snapdf.bond"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project   = "snapdf"
    ManagedBy = "terragrunt"
  }
}

resource "aws_route53_record" "dev_wildcard_validation" {
  for_each = {
    for dvo in aws_acm_certificate.dev_wildcard.domain_validation_options : dvo.resource_record_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }...
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value[0].name
  type    = each.value[0].type
  ttl     = 60
  records = [each.value[0].value]
}

resource "aws_acm_certificate_validation" "dev_wildcard" {
  certificate_arn         = aws_acm_certificate.dev_wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.dev_wildcard_validation : record.fqdn]
}

# ── GitHub PAT for the ArgoCD webhook resource ───────────────────────────────
resource "aws_secretsmanager_secret" "github_pat" {
  name                    = "snapdf/github-pat"
  description             = "GitHub PAT the argocd module uses to keep this repo's ArgoCD webhook secret in sync"
  recovery_window_in_days = 0

  tags = { Project = "snapdf", ManagedBy = "terragrunt" }
}

resource "aws_secretsmanager_secret_version" "github_pat" {
  secret_id     = aws_secretsmanager_secret.github_pat.id
  secret_string = var.github_pat

  lifecycle {
    ignore_changes = [secret_string]
  }
}
