locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads prod/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/sqs" # points to infra/modules/sqs
}

inputs = {
  env_name     = local.env.locals.env_name     # "prod"
  cluster_name = local.env.locals.cluster_name # "snapdf-prod"
}
