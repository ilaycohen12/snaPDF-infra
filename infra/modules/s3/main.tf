data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "pdfs" {
  for_each = toset(var.app_namespaces)

  bucket        = "snapdf-${each.value}-pdfs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Environment = var.env_name
    ManagedBy   = "terragrunt"
  }
}

resource "aws_s3_bucket_public_access_block" "pdfs" {
  for_each = aws_s3_bucket.pdfs

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
