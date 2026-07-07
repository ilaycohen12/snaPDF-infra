variable "env_name" {
  description = "Environment name (dev or prod) — used in Secrets Manager paths and to pick the right gitops path (apps/dev vs apps/prod)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used by Helm/Kubernetes providers to authenticate via aws eks get-token, and by the root-bootstrap kubectl call"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server URL — Helm/Kubernetes providers use this to talk to the cluster"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 CA certificate — Helm/Kubernetes providers use this to verify the cluster identity"
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone ID for snapdf.bond, from the global module — used to create ArgoCD's own DNS record"
  type        = string
}

variable "domain_name" {
  description = "Root domain — snapdf.bond"
  type        = string
}

variable "argocd_hostname" {
  description = "Subdomain label for this environment's ArgoCD UI, e.g. \"argocd-dev\" or \"argocd-prod\""
  type        = string
}

variable "github_pat_secret_arn" {
  description = "ARN of the GitHub PAT secret (from the global module) — used to authenticate the github provider that manages this repo's ArgoCD webhook"
  type        = string
}
