variable "env_name" {
  description = "Environment name (dev or prod) — used in tags and Secrets Manager paths"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used by Helm/Kubernetes providers to authenticate via aws eks get-token"
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

variable "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI driver — annotated onto its service account via the EKS addon's service_account_role_arn"
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone ID for snapdf.bond, from the global module — used to create Grafana's DNS record"
  type        = string
}

variable "domain_name" {
  description = "Root domain — snapdf.bond"
  type        = string
}

variable "grafana_hostname" {
  description = "Subdomain label for this environment's Grafana UI. Dev uses the wildcard-DNS form \"grafana.dev\" (dot); prod still uses the flat \"grafana-prod\" form."
  type        = string
}
