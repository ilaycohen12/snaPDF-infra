locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads prod/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/addons" # points to infra/modules/addons

  # Delete AWS Load Balancers BEFORE terraform destroy runs.
  # ALBs are created by the ALB controller (outside Terraform state). If they're
  # not deleted before the EKS cluster is torn down, the VPC deletion will fail
  # because orphaned ALBs/security-groups still reference the VPC subnets.
  before_hook "delete_load_balancers" {
    commands = ["destroy"]
    execute = [
      "bash", "-c",
      join(" && ", [
        "echo 'Deleting LoadBalancer services to trigger ALB cleanup...'",
        "aws eks update-kubeconfig --region us-east-1 --name snapdf-${local.env.locals.env_name} 2>/dev/null || true",
        "kubectl delete svc ingress-nginx-controller -n ingress-nginx --ignore-not-found 2>/dev/null || true",
        "kubectl delete svc argocd-server -n argocd --ignore-not-found 2>/dev/null || true",
        "echo 'Waiting 90s for AWS to finish deleting ALBs...'",
        "sleep 90",
        "echo 'Proceeding with terraform destroy.'"
      ])
    ]
  }
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "snapdf-prod"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "iam" {
  config_path = "../iam"

  mock_outputs = {
    alb_controller_role_arn = "arn:aws:iam::123456789012:role/snapdf-prod-alb-controller"
    eso_role_arn            = "arn:aws:iam::123456789012:role/snapdf-prod-eso"
    keda_role_arn           = "arn:aws:iam::123456789012:role/snapdf-prod-keda"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "global" {
  config_path = "../../../global"

  mock_outputs = {
    route53_zone_id = "Z0000000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  env_name                           = local.env.locals.env_name
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  vpc_id                             = dependency.vpc.outputs.vpc_id
  alb_controller_role_arn            = dependency.iam.outputs.alb_controller_role_arn
  eso_role_arn                       = dependency.iam.outputs.eso_role_arn
  keda_role_arn                      = dependency.iam.outputs.keda_role_arn
  route53_zone_id                    = dependency.global.outputs.route53_zone_id
  domain_name                        = "snapdf.bond"
  app_hostnames                      = ["prod"]
  argocd_hostname                    = "argocd-prod"
}
