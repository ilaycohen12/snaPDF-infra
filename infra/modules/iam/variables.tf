variable "env_name" {
  description = "Environment name (dev or prod) — used in resource names and tags"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used to name IAM roles e.g. projectview-dev-alb-controller"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS cluster — used to build IRSA trust policies"
  type        = string
}
