variable "cluster_name" {
  description = "EKS cluster name — used by Helm provider to authenticate via aws eks get-token, and passed to Karpenter itself"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server URL — Helm provider uses this to talk to the cluster, and passed to Karpenter itself"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 CA certificate — Helm provider uses this to verify the cluster identity"
  type        = string
}

variable "karpenter_controller_role_arn" {
  description = "IAM role ARN for the Karpenter controller — annotated onto its service account via Helm values"
  type        = string
}

variable "karpenter_node_role_arn" {
  description = "IAM role ARN for Karpenter-provisioned nodes — granted an EKS access entry here so those nodes can actually authenticate and register with the cluster"
  type        = string
}
