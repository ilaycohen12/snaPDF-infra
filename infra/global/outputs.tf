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

output "route53_zone_id" {
  description = "Hosted zone ID for snapdf.bond — used by dev/prod addons modules to create CNAME records"
  value       = aws_route53_zone.main.zone_id
}

output "route53_name_servers" {
  description = "Nameservers for snapdf.bond — must be set as the domain's nameservers at the registrar (GoDaddy) to delegate DNS to Route53"
  value       = aws_route53_zone.main.name_servers
}
