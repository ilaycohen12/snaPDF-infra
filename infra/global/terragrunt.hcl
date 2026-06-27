include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "." # global has no separate modules/ folder — the .tf files live here directly
}
