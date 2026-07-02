locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads prod/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/s3" # points to infra/modules/s3
}

inputs = {
  env_name = local.env.locals.env_name # "prod"
  # "prod" here, not "production" — matches the existing bucket name
  # (snapdf-prod-pdfs-...) already live in AWS. Same reasoning as sqs/terragrunt.hcl.
  app_namespaces = ["prod"]
}
