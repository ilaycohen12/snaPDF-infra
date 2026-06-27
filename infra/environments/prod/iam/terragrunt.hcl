locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads prod/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/iam" # points to infra/modules/iam
}

dependency "eks" {
  config_path = "../eks" # reads eks outputs from S3 state

  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXX" # fake ARN for plan/validate
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"] # use mocks only during plan/validate, never during apply
}

inputs = {
  env_name          = local.env.locals.env_name       # "prod"
  cluster_name      = local.env.locals.cluster_name   # "projectview-prod"
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn # real value from eks state during apply
}
