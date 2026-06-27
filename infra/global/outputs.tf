output "ecr_repository_url" {
  description = "ECR repository URL — used by GitHub Actions to push images and by EKS to pull them"
  value       = aws_ecr_repository.app.repository_url
  # e.g. "086241318869.dkr.ecr.us-east-1.amazonaws.com/projectview-app"
}

output "api_key_secret_arn" {
  description = "API key secret ARN — used by ESO to sync the key into Kubernetes as a secret"
  value       = aws_secretsmanager_secret.api_key.arn
}
