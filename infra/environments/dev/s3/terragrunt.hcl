locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads dev/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/s3" # points to infra/modules/s3
}

inputs = {
  env_name     = local.env.locals.env_name     # "dev"
  cluster_name = local.env.locals.cluster_name # "snapdf-dev"
}
