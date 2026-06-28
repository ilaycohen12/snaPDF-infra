locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads dev/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/eks" # points to infra/modules/eks
}

dependency "vpc" {
  config_path = "../vpc" # reads vpc outputs from S3 state

  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"        # fake VPC ID for plan/validate
    private_subnet_ids = ["subnet-00000000000000000",   # fake subnet IDs for plan/validate
                          "subnet-11111111111111111"]
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"] # use mocks only during plan/validate, never during apply
}

inputs = {
  env_name           = local.env.locals.env_name            # "dev"
  cluster_name       = local.env.locals.cluster_name        # "snapdf-dev"
  node_instance_type = local.env.locals.node_instance_type  # "t3.small"
  vpc_id             = dependency.vpc.outputs.vpc_id        # real value from vpc state during apply
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids # real value from vpc state during apply
}
