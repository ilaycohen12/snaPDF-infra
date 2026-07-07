# ============================================================
# Root Terragrunt config — inherited by ALL environment modules
# ============================================================

# Block 1 — Shared values used inside this file only
locals {
  aws_region = "us-east-1"
  account_id = "086241318869"
  bucket     = "projectview-tf-state-${local.account_id}"
}

# Block 2 — Where to store Terraform state files
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket       = local.bucket
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    use_lockfile = true
  }
}

# Block 3 — Inject an AWS provider into every module automatically
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
}

terraform {
  required_version = ">= 1.10.0"
}
EOF
}
