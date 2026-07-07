locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/rds"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id                     = "vpc-00000000000000000"
    database_subnet_group_name = "snapdf-dev"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    node_security_group_id = "sg-00000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  env_name                   = local.env.locals.env_name
  cluster_name               = local.env.locals.cluster_name
  vpc_id                     = dependency.vpc.outputs.vpc_id
  database_subnet_group_name = dependency.vpc.outputs.database_subnet_group_name
  node_security_group_id     = dependency.eks.outputs.node_security_group_id
}
