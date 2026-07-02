output "bucket_names" {
  description = "Bucket names, keyed by namespace — used by workers to upload PDFs and by web server to generate presigned URLs"
  value       = { for ns, b in aws_s3_bucket.pdfs : ns => b.bucket }
}

output "bucket_arns" {
  description = "Bucket ARNs, keyed by namespace — used by IAM to write permission policies for workers"
  value       = { for ns, b in aws_s3_bucket.pdfs : ns => b.arn }
}
