locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads dev/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/rds" # points to infra/modules/rds
}

dependency "vpc" {
  config_path = "../vpc" # reads vpc outputs from S3 state

  mock_outputs = {
    vpc_id                     = "vpc-00000000000000000"  # fake VPC ID for plan/validate
    database_subnet_group_name = "snapdf-dev"        # fake subnet group name for plan/validate
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "eks" {
  config_path = "../eks" # reads eks outputs from S3 state

  mock_outputs = {
    node_security_group_id = "sg-00000000000000000" # fake security group ID for plan/validate
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  env_name                   = local.env.locals.env_name                         # "dev"
  cluster_name               = local.env.locals.cluster_name                     # "snapdf-dev"
  vpc_id                     = dependency.vpc.outputs.vpc_id                     # from vpc module
  database_subnet_group_name = dependency.vpc.outputs.database_subnet_group_name # from vpc module
  node_security_group_id     = dependency.eks.outputs.node_security_group_id     # from eks module
}
