# ============================================================
# env.hcl — Prod environment values
# Read by every module inside environments/prod/ via read_terragrunt_config()
# ============================================================

locals {
  env_name           = "prod"              # environment label — used in resource names and tags
  cluster_name       = "projectview-prod"  # EKS cluster name as it will appear in AWS
  node_instance_type = "t3.small"          # EC2 instance type for worker nodes
}
