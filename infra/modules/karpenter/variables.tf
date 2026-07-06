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

variable "env_name" {
  description = "Environment name (dev or prod) — used in the node instance profile name and subnet/security-group discovery tag values"
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types Karpenter is allowed to launch, e.g. [\"t3.micro\",\"t3.small\",\"t3.medium\"] for dev or [\"t3.medium\",\"t3.large\",\"t3.xlarge\"] for prod"
  type        = list(string)
}

variable "node_cpu_limit" {
  description = "Total vCPU Karpenter is allowed to provision across all its nodes at once, e.g. \"6\" for dev or \"9\" for prod"
  type        = string
}

variable "node_memory_limit" {
  description = "Total memory Karpenter is allowed to provision across all its nodes at once, e.g. \"12Gi\" for dev or \"18Gi\" for prod"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — the Fargate profile running Karpenter's own controller needs these, same subnets Karpenter-launched worker nodes and the EKS managed node group already use"
  type        = list(string)
}
