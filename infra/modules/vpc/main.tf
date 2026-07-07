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
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "snapdf-${var.env_name}"
  cidr = var.vpc_cidr

  azs              = local.azs
  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Environment = var.env_name
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}
