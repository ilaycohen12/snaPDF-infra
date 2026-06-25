locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads dev/env.hcl
}

include "root" {
  path = find_in_parent_folders() # walks up and finds infra/terragrunt.hcl — inherits S3 backend + provider
}

terraform {
  source = "../../../modules/vpc" # points to infra/modules/vpc
}

inputs = {
  env_name = local.env.locals.env_name # "dev" — pulled from dev/env.hcl
}
