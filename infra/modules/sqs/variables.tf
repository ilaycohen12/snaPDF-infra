variable "env_name" {
  description = "Environment name (dev or prod) — used in tags"
  type        = string
}

variable "app_namespaces" {
  description = "Application namespaces in this cluster that each need their own signed+free queue pair, e.g. [\"dev\", \"staging\"] or [\"production\"]"
  type        = list(string)
}
