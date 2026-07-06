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

variable "acm_certificate_arn" {
  description = "Validated wildcard cert ARN for *.snapdf.bond, from the global module's output — wired directly into the ALB Ingress's certificate-arn annotation now that this Ingress is Terraform-managed instead of a gitops YAML file with the ARN pasted in by hand"
  type        = string
}

variable "additional_certificate_arns" {
  description = "Extra cert ARNs to attach to the shared ALB listener alongside acm_certificate_arn (comma-separated on the same annotation, additive via SNI) — e.g. the *.dev.snapdf.bond cert for infra #28's nested-wildcard experiment. Empty by default; prod doesn't set this."
  type        = list(string)
  default     = []
}

variable "wildcard_hostnames" {
  description = "Subdomain labels to create a *.{label}.domain_name wildcard CNAME for (e.g. [\"dev\"] creates *.dev.snapdf.bond) — infra #28 experiment, replaces one-off per-service records like grafana-dev/argocd-dev. Empty by default."
  type        = list(string)
  default     = []
}

variable "rds_resource_id" {
  description = "RDS instance's AWS-internal resource_id (not its identifier — this changes on every real instance recreate). Used to key the one-off staging-database job so it only re-runs when the instance is genuinely new. Empty string on environments with no staging database (e.g. prod)."
  type        = string
  default     = ""
}
