# ============================================================
# Root Terragrunt config — inherited by ALL environment modules
# ============================================================

# Block 1 — Shared values used inside this file only
locals {
  aws_region = "us-east-1"                                     # the AWS region for everything in this project
  account_id = "086241318869"                                   # your AWS account ID
  bucket     = "snapdf-tf-state-${local.account_id}"      # S3 bucket name — built from account_id for global uniqueness
}

# Block 2 — Where to store Terraform state files
remote_state {
  backend = "s3"                                                # use S3 as the backend (not local file)
  generate = {
    path      = "backend.tf"                                    # Terragrunt auto-creates this file in each module before running
    if_exists = "overwrite"                                     # overwrite every run to keep it in sync
  }
  config = {
    bucket       = local.bucket                                 # the S3 bucket we created in Phase 0
    key          = "${path_relative_to_include()}/terraform.tfstate" # unique path per module e.g. environments/dev/vpc/terraform.tfstate
    region       = local.aws_region                             # which region the S3 bucket lives in
    use_lockfile = true                                         # S3 native locking — creates .tflock file during apply
  }
}

# Block 3 — Inject an AWS provider into every module automatically
# Without this, every module would need its own provider.tf file
generate "provider" {
  path      = "provider.tf"                                     # file Terragrunt creates inside each module folder before running
  if_exists = "overwrite"                                       # overwrite every run to keep it in sync with this config
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
}

terraform {
  required_version = ">= 1.10.0"
}
EOF
}
