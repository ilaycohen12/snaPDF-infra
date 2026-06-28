module "eks" {
  source  = "terraform-aws-modules/eks/aws"  # official community module
  version = "~> 20.0"

  cluster_name    = var.cluster_name          # e.g. "snapdf-dev"
  cluster_version = "1.31"                    # Kubernetes version

  vpc_id     = var.vpc_id                     # which VPC to put the cluster in
  subnet_ids = var.private_subnet_ids         # worker nodes go in private subnets

  cluster_endpoint_public_access           = true  # lets you run kubectl from your laptop
  enable_irsa                              = true  # enables OIDC — required for ESO and ALB controller
  enable_cluster_creator_admin_permissions = true  # gives you kubectl admin access after apply

  eks_managed_node_groups = {
    default = {
      name           = "${var.cluster_name}-nodes"  # e.g. "snapdf-dev-nodes"
      instance_types = [var.node_instance_type]     # ["t3.small"]
      min_size       = 1                            # never go below 1 node
      max_size       = 3                            # can scale up to 3 under load
      desired_size   = 2                            # start with 2 nodes — one per AZ
    }
  }

  access_entries = {
    github-actions = {
      principal_arn = "arn:aws:iam::086241318869:role/github-actions-ci"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = {
    Environment = var.env_name   # "dev" or "prod"
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}
