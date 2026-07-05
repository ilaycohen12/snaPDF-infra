include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/karpenter"
}

# Pure ordering — needs alb_controller (addons) ready before Karpenter installs.
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
}
