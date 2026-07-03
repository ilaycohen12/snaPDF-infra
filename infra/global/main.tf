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

# ── Route53 Hosted Zone ───────────────────────────────────────────────────────
# One DNS zone shared by dev, staging, and prod hostnames (dev./staging./prod.snapdf.bond).
# After apply, the zone's name_servers output must be set as snapdf.bond's nameservers
# in GoDaddy (or wherever the domain is registered) to actually delegate DNS to Route53.

resource "aws_route53_zone" "main" {
  name = "snapdf.bond"

  tags = {
    Project   = "snapdf"
    ManagedBy = "terragrunt"
  }
}

# ── ACM Certificate for TLS (infra #19) ──────────────────────────────────────
# One wildcard cert covers every current and future subdomain (dev./prod./
# argocd-prod./grafana-*.snapdf.bond) — no need to request a new cert per env
# or per addon. Must be requested in us-east-1 since it's attached to a
# regional ALB here, not CloudFront (which would require us-east-1 regardless
# of where the ALB actually is — not a constraint we need to think about since
# this whole project already lives in us-east-1).
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

# ACM's proof-of-ownership check: it hands us a specific CNAME name/value pair
# per domain and expects to find it in the zone's real DNS records. Only the
# actual owner of the zone could create these, which is what convinces ACM to
# issue the cert. Keyed by the record name (not domain_name) because ACM
# often issues the *same* validation CNAME for an apex + its wildcard SAN —
# keying by domain_name tried to create that identical record twice and the
# second attempt collided with the first ("already exists").
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.resource_record_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }...
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value[0].name # [0]: the "..." grouping above turns each.value into a list of
  type    = each.value[0].type # the (identical, in this case) duplicates sharing this key —
  ttl     = 60                 # only the first is needed since they're the same record.
  records = [each.value[0].value]
}

# Blocks here until ACM actually sees the validation records and flips the
# certificate to ISSUED — so anything depending on this resource (or its
# output) can't run before the cert is genuinely usable.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}
