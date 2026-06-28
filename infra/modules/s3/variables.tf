variable "env_name" {
  description = "Environment name (dev or prod) — used in tags"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name — used to name the bucket e.g. snapdf-dev"
  type        = string
}
