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
  env_name = local.env.locals.env_name # "prod"
  # "prod" here, not "production" — matches the existing queue names
  # (snapdf-prod-signed/free) already live in AWS. This is just a naming string for
  # the AWS resource, unrelated to the k8s namespace name (which the iam module's
  # app_namespaces below is what actually needs to match exactly).
  app_namespaces = ["prod"]
}
