locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/argocd"
}

# Needs addons's alb_controller + nginx + nginx-alb Ingress ready before
# ArgoCD's own Ingress/DNS record mean anything. No addons output is actually
# consumed (this module reads the shared Ingress live, same object, via its
# own data source) — this is pure ordering.
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
    route53_zone_id = "Z0000000000000000000"
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
  argocd_hostname                    = "argocd-dev"
}
