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

  # VPC CNI explicitly managed here (was previously left as AWS's untracked default).
  # Prefix delegation raises pod density per node from ~17 (one IP per pod, limited by
  # each node's ENIs) to well over 100, by handing out /28 blocks of 16 IPs at a time
  # instead of one IP at a time. kubelet's own max-pods is capped separately below at 35
  # — a deliberate ceiling for near-term headroom (Karpenter, Prometheus/Grafana), not
  # the raw maximum the CNI could technically support.
  cluster_addons = {
    vpc-cni = {
      before_compute = true # install before nodes launch, so they boot with the right CNI config
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
      name           = "${var.cluster_name}-nodes"  # e.g. "snapdf-dev-nodes"
      instance_types = [var.node_instance_type]     # ["t3.medium"]
      # infra #24: shrunk from min=1/max=3/desired=2 now that Karpenter is proven
      # (real scale-up/scale-down watched live on both dev and prod, Phase 6/v0.7.0).
      # This group is now just a fixed floor — somewhere for CoreDNS, the ALB
      # Controller, and Karpenter's own controller pod to run even before Karpenter
      # has provisioned anything itself — not a second source of elasticity.
      # Karpenter's NodePool (6 vCPU/12GiB dev, 9 vCPU/18GiB prod) owns all real
      # demand above this floor now.
      min_size       = 1                            # never zero — Karpenter itself needs somewhere to run
      max_size       = 1
      desired_size   = 1

      # Explicit, not left to default — the module only generates nodeadm-format user
      # data (required for cloudinit_pre_nodeadm below to actually take effect) when
      # ami_type is explicitly AL2023_*. Left as null/default, it silently falls back
      # to the legacy bootstrap.sh format and ignores cloudinit_pre_nodeadm entirely.
      ami_type = "AL2023_x86_64_STANDARD"

      # Amazon Linux 2023 nodes use nodeadm, configured via a NodeConfig document
      # injected before nodeadm runs. This overrides kubelet's default max-pods
      # (normally auto-calculated from instance type + CNI) with our own ceiling.
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
    Environment = var.env_name   # "dev" or "prod"
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}

# Karpenter discovers which subnets it's allowed to launch nodes into via this
# tag (referenced in the EC2NodeClass's subnetSelectorTerms) — existing tags
# (Environment, Project) aren't precise enough on their own since they also
# match the public and database subnets, not just the private ones nodes go in.
resource "aws_ec2_tag" "karpenter_subnet_discovery" {
  for_each = toset(var.private_subnet_ids)

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}
