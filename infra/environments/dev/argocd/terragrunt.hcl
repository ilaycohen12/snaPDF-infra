locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/argocd"
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

dependency "global" {
  config_path = "../../../global"

  mock_outputs = {
    route53_zone_id       = "Z0000000000000000000"
    github_pat_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:snapdf/github-pat-mock"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  env_name                           = local.env.locals.env_name
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  route53_zone_id                    = dependency.global.outputs.route53_zone_id
  domain_name                        = "snapdf.bond"
  argocd_hostname                    = "argocd.dev"
  github_pat_secret_arn              = dependency.global.outputs.github_pat_secret_arn
  github_oauth_client_id             = "Ov23li55n7xJZR6ED5Uz"
  sso_github_username                = "ilaycohen12"
}
