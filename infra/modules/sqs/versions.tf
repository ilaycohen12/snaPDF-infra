terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # This module's state was already written by AWS provider v6 (dev:
      # 6.52.0, prod: 6.53.0) before this constraint existed. Terraform
      # refuses to let an older provider touch state written by a newer
      # one, so unlike every other module here (pinned to ~> 5.0), this
      # one is pinned to match its actual state rather than risk a forced
      # downgrade against a live, in-use queue.
      version = "~> 6.0"
    }
  }
}
