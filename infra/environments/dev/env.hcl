# ============================================================
# env.hcl — Dev environment values
# Read by every module inside environments/dev/ via read_terragrunt_config()
# ============================================================

locals {
  env_name           = "dev"
  cluster_name       = "snapdf-dev"
  node_instance_type = "t3.medium"
}
