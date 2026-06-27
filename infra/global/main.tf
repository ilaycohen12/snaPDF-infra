# ── ECR Repository ───────────────────────────────────────────────────────────
# One registry shared by both dev and prod clusters
# NOTE: already created manually in Phase 0 — import with:
#   terragrunt import aws_ecr_repository.app projectview-app

resource "aws_ecr_repository" "app" {
  name                 = "projectview-app"
  image_tag_mutability = "MUTABLE" # allows overwriting tags e.g. :latest

  image_scanning_configuration {
    scan_on_push = true # scans every pushed image for known CVEs automatically
  }

  tags = {
    Project   = "projectview"
    ManagedBy = "terragrunt"
  }
}

# ── API Key Secret ────────────────────────────────────────────────────────────
# Creates the slot in Secrets Manager — value is set manually after apply:
#   aws secretsmanager put-secret-value \
#     --secret-id projectview/api-key \
#     --secret-string "your-actual-api-key-here"

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "projectview/api-key"
  description             = "API key for signed users — checked by the Flask web server via X-API-Key header"
  recovery_window_in_days = 0 # allows immediate deletion with terraform destroy (default is 30 day wait)

  tags = {
    Project   = "projectview"
    ManagedBy = "terragrunt"
  }
}
