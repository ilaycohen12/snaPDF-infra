output "alb_controller_role_arn" {
  description = "IAM role ARN for the ALB Ingress Controller — annotated onto its service account"
  value       = aws_iam_role.alb_controller.arn
}

output "eso_role_arn" {
  description = "IAM role ARN for the External Secrets Operator — annotated onto its service account"
  value       = aws_iam_role.eso.arn
}
