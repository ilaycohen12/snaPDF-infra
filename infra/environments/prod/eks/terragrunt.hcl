locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/eks"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    private_subnet_ids = ["subnet-00000000000000000",
                          "subnet-11111111111111111"]
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  env_name           = local.env.locals.env_name
  cluster_name       = local.env.locals.cluster_name
  node_instance_type = local.env.locals.node_instance_type
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids
}
