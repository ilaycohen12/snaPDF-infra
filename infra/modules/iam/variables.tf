variable "env_name" {
  description = "Environment name (dev or prod) — used in resource names and tags"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used to name IAM roles e.g. snapdf-dev-alb-controller"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS cluster — used to build IRSA trust policies"
  type        = string
}

variable "signed_queue_arns" {
  description = "ARNs of every signed SQS queue this cluster's namespaces use — used in KEDA and worker IAM policies"
  type        = list(string)
}

variable "free_queue_arns" {
  description = "ARNs of every free SQS queue this cluster's namespaces use — used in worker IAM policy"
  type        = list(string)
}

variable "bucket_arns" {
  description = "ARNs of every PDF S3 bucket this cluster's namespaces use — used in worker IAM policy"
  type        = list(string)
}

variable "app_namespaces" {
  description = "Application namespaces in this cluster that need the worker IAM role — dev cluster: [\"dev\", \"staging\"], prod cluster: [\"production\"]"
  type        = list(string)
}
