data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "pdfs" {
  bucket        = "${var.cluster_name}-pdfs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # delete all objects automatically on terraform destroy

  tags = {
    Environment = var.env_name
    ManagedBy   = "terragrunt"
  }
}

resource "aws_s3_bucket_public_access_block" "pdfs" {
  bucket = aws_s3_bucket.pdfs.id

  block_public_acls       = true # nobody can make objects public via ACL
  block_public_policy     = true # nobody can attach a public bucket policy
  ignore_public_acls      = true # ignore any existing public ACLs
  restrict_public_buckets = true # block all public access regardless of ACLs
}
