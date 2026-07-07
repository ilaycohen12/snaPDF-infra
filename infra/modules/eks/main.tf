# -----EKS Cluster-----
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access           = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      name           = "${var.cluster_name}-nodes"
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 1
      desired_size   = 1

      ami_type = "AL2023_x86_64_STANDARD"

      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content = yamlencode({
            apiVersion = "node.eks.aws/v1alpha1"
            kind       = "NodeConfig"
            spec = {
              kubelet = {
                config = {
                  maxPods = 35
                }
              }
            }
          })
        }
      ]
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
    Environment = var.env_name
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}

# -----CoreDNS access for Karpenter Fargate profile-----
resource "aws_security_group_rule" "node_ingress_cluster_coredns_tcp" {
  description              = "Cluster/Fargate SG to node CoreDNS TCP"
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = 53
  to_port                  = 53
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
}

resource "aws_security_group_rule" "node_ingress_cluster_coredns_udp" {
  description              = "Cluster/Fargate SG to node CoreDNS UDP"
  type                     = "ingress"
  protocol                 = "udp"
  from_port                = 53
  to_port                  = 53
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
}

# -----Karpenter subnet discovery tag-----
resource "aws_ec2_tag" "karpenter_subnet_discovery" {
  for_each = toset(var.private_subnet_ids)

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}
