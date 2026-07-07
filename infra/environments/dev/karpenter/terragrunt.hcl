locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/karpenter"
}

dependencies {
  paths = ["../addons"]
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "snapdf-dev"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "iam" {
  config_path = "../iam"

  mock_outputs = {
    karpenter_controller_role_arn = "arn:aws:iam::123456789012:role/snapdf-dev-karpenter-controller"
    karpenter_node_role_arn       = "arn:aws:iam::123456789012:role/snapdf-dev-karpenter-node"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  karpenter_controller_role_arn      = dependency.iam.outputs.karpenter_controller_role_arn
  karpenter_node_role_arn            = dependency.iam.outputs.karpenter_node_role_arn
  env_name                           = local.env.locals.env_name
  node_instance_types                = ["t3.micro", "t3.small", "t3.medium"]
  node_cpu_limit                     = "6"
  node_memory_limit                  = "12Gi"
  private_subnet_ids                 = dependency.vpc.outputs.private_subnet_ids
}
