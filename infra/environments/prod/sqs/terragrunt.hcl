locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/sqs"
}

inputs = {
  env_name       = local.env.locals.env_name
  app_namespaces = ["prod"]
}
