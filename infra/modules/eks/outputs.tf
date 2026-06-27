output "cluster_name" {
  description = "EKS cluster name — used by addons and kubectl"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server URL — used by Helm and kubectl to talk to the cluster"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA certificate — used to verify the cluster identity when connecting"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used by IAM module if going with IRSA"
  value       = module.eks.oidc_provider_arn
}

output "node_group_role_arn" {
  description = "IAM role ARN of the worker nodes — used to attach extra policies"
  value       = module.eks.eks_managed_node_groups["default"].iam_role_arn
}

output "node_security_group_id" {
  description = "Security group ID of the EKS worker nodes — used by RDS to allow port 5432 from nodes only"
  value       = module.eks.node_security_group_id
}
