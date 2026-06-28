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

variable "signed_queue_arn" {
  description = "ARN of the signed SQS queue — used in KEDA and worker IAM policies"
  type        = string
}

variable "free_queue_arn" {
  description = "ARN of the free SQS queue — used in worker IAM policy"
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the PDF S3 bucket — used in worker IAM policy"
  type        = string
}
