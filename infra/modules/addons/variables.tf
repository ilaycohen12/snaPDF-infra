variable "env_name" {
  description = "Environment name (dev or prod) — used in tags"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used by Helm provider to authenticate via aws eks get-token"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server URL — Helm provider uses this to talk to the cluster"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 CA certificate — Helm provider uses this to verify the cluster identity"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — passed to ALB controller so it knows which VPC to create load balancers in"
  type        = string
}

variable "alb_controller_role_arn" {
  description = "IAM role ARN for ALB controller — annotated onto its service account via Helm values"
  type        = string
}

variable "eso_role_arn" {
  description = "IAM role ARN for ESO — annotated onto its service account via Helm values"
  type        = string
}

variable "keda_role_arn" {
  description = "IAM role ARN for KEDA — annotated onto its service account via Helm values"
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone ID for snapdf.bond, from the global module — used to create this environment's DNS records"
  type        = string
}

variable "domain_name" {
  description = "Root domain — snapdf.bond"
  type        = string
}

variable "app_hostnames" {
  description = "Subdomain labels that should point at this environment's Nginx ingress LB, e.g. [\"dev\",\"staging\"] or [\"prod\"]"
  type        = list(string)
}

variable "argocd_hostname" {
  description = "Subdomain label for this environment's ArgoCD UI, e.g. \"argocd-dev\" or \"argocd-prod\""
  type        = string
}
