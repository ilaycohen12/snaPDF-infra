module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"  # official community module
  version = "~> 5.0"                          # any 5.x version

  name = "snapdf-${var.env_name}"        # e.g. "snapdf-dev"
  cidr = var.vpc_cidr                         # 10.0.0.0/16

  azs              = var.azs                   # ["us-east-1a", "us-east-1b"]
  public_subnets   = var.public_subnet_cidrs   # ALB + NAT Gateway
  private_subnets  = var.private_subnet_cidrs  # EKS worker nodes
  database_subnets = var.database_subnet_cidrs # RDS

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
