output "ecr_api_url" {
  description = "ECR URL for the api service image"
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_worker_url" {
  description = "ECR URL for the worker service image"
  value       = aws_ecr_repository.worker.repository_url
}

output "ecr_auth_url" {
  description = "ECR URL for the auth service image"
  value       = aws_ecr_repository.auth.repository_url
}

output "api_key_secret_arn" {
  description = "API key secret ARN — used by ESO to sync the key into Kubernetes as a secret"
  value       = aws_secretsmanager_secret.api_key.arn
}
