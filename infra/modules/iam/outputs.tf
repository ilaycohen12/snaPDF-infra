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

output "api_role_arn" {
  description = "IAM role ARN for the api service — annotated onto the api service account. Split out from worker_role_arn for least-privilege (api only sends to SQS + S3 read/write, never receives/deletes)"
  value       = aws_iam_role.api.arn
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN for the Karpenter controller — annotated onto its service account"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_instance_profile_name" {
  description = "Instance profile name for Karpenter-provisioned nodes — referenced by the EC2NodeClass"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN for Karpenter-provisioned nodes — needs an EKS access entry (created in the addons module, not here, to avoid a circular dependency between iam and eks) before nodes using it can actually register with the cluster"
  value       = aws_iam_role.karpenter_node.arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI driver — the addon itself is created in the addons module, not here, for the same circular-dependency reason as Karpenter's access entry"
  value       = aws_iam_role.ebs_csi.arn
}
