variable "env_name" {
  description = "Environment name (dev or prod) — used in tags"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name — used to name the queues e.g. snapdf-dev-signed"
  type        = string
}
