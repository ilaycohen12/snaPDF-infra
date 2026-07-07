locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/iam"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXX"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "sqs" {
  config_path = "../sqs"

  mock_outputs = {
    signed_queue_arns = { production = "arn:aws:sqs:us-east-1:123456789012:snapdf-production-signed" }
    free_queue_arns   = { production = "arn:aws:sqs:us-east-1:123456789012:snapdf-production-free" }
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "s3" {
  config_path = "../s3"

  mock_outputs = {
    bucket_arns = { production = "arn:aws:s3:::snapdf-production-pdfs-123456789012" }
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  env_name          = local.env.locals.env_name
  cluster_name      = local.env.locals.cluster_name
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
  signed_queue_arns = values(dependency.sqs.outputs.signed_queue_arns)
  free_queue_arns   = values(dependency.sqs.outputs.free_queue_arns)
  bucket_arns       = values(dependency.s3.outputs.bucket_arns)
  app_namespaces    = ["production"]
}
