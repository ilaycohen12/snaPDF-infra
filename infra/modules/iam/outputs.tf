output "alb_controller_role_arn" {
  description = "IAM role ARN for the ALB Ingress Controller — annotated onto its service account"
  value       = aws_iam_role.alb_controller.arn
}

output "eso_role_arn" {
  description = "IAM role ARN for the External Secrets Operator — annotated onto its service account"
  value       = aws_iam_role.eso.arn
}

output "keda_role_arn" {
  description = "IAM role ARN for KEDA — annotated onto the keda-operator service account"
  value       = aws_iam_role.keda.arn
}

output "worker_role_arn" {
  description = "IAM role ARN for PDF workers — annotated onto the worker service account"
  value       = aws_iam_role.worker.arn
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN for the Karpenter controller — annotated onto its service account"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_instance_profile_name" {
  description = "Instance profile name for Karpenter-provisioned nodes — referenced by the EC2NodeClass"
  value       = aws_iam_instance_profile.karpenter_node.name
}
