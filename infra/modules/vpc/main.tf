# Discovers AZs and computes every tier's subnet CIDRs from var.vpc_cidr,
# instead of hand-maintaining 4 parallel lists (azs + one per subnet tier)
# that had to be kept in sync by hand every time the AZ count changed.
# Offsets (+1/+3/+5) deliberately chosen to reproduce the exact CIDRs already
# live (10.0.1-2 public, 10.0.3-4 private, 10.0.5-6 database) at az_count=2 —
# confirmed via `terraform plan` -> "No changes" before this was ever applied.
# A wider spacing (e.g. +0/+10/+20) was tried first and produced a 13-resource
# destroy/recreate plan against the live dev VPC (every subnet's CIDR would
# have shifted) — reverted specifically to avoid that. Real tradeoff of this
# choice: only collision-free up to 2 AZs (a 3rd public subnet would land on
# 10.0.4.0/24, colliding with private's first one) — acceptable given this
# project deliberately runs single_nat_gateway = true and shows no sign of
# needing more than 2 AZs.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs              = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 3)]
  database_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 5)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"  # official community module
  version = "~> 5.0"                          # any 5.x version

  name = "snapdf-${var.env_name}"        # e.g. "snapdf-dev"
  cidr = var.vpc_cidr                         # 10.0.0.0/16

  azs              = local.azs               # discovered dynamically, not hardcoded
  public_subnets   = local.public_subnets    # ALB + NAT Gateway
  private_subnets  = local.private_subnets   # EKS worker nodes
  database_subnets = local.database_subnets  # RDS

  enable_nat_gateway   = true                  # create a NAT Gateway
  single_nat_gateway   = true                  # one NAT shared across AZs — saves cost
  enable_dns_hostnames = true                  # required by EKS
  enable_dns_support   = true                  # required by EKS

  create_database_subnet_group = true          # auto-creates the subnet group RDS needs

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1               # ALB Ingress Controller: put public ALBs here
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1      # ALB Ingress Controller: put internal ALBs here
  }

  tags = {
    Environment = var.env_name                  # "dev" or "prod"
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}
