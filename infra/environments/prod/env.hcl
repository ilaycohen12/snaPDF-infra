# ============================================================
# env.hcl — Prod environment values
# Read by every module inside environments/prod/ via read_terragrunt_config()
# ============================================================

locals {
  env_name           = "prod"
  cluster_name       = "snapdf-prod"
  node_instance_type = "t3.medium"
}
