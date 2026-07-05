# ── Helm Provider ─────────────────────────────────────────────────────────────
provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    }
  }
}

# ── Karpenter ─────────────────────────────────────────────────────────────────
# Node autoscaling — installed alongside the existing managed node group. The
# managed node group isn't shrunk further than its current fixed baseline;
# Karpenter provisions additional capacity on top of it.
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "kube-system"
  version    = "1.1.1"
  wait       = true # must be genuinely ready before we trust it to manage capacity
  timeout    = 300

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.karpenter_controller_role_arn
  }

  # infra #24: the chart defaults to 2 replicas with a hard pod anti-affinity
  # (no two replicas on the same node) and a zone-spread topology constraint —
  # fine when the managed node group had 2+ nodes, but deadlocks now that it's
  # shrunk to a single fixed baseline node: Karpenter's own 2nd replica can
  # never find a second permanent node to land on, so it sits Pending forever
  # (confirmed live: "didn't match pod topology spread constraints"). Karpenter
  # doesn't need HA at this project's scale — losing it briefly only pauses new
  # scheduling decisions, it doesn't affect already-running pods/nodes.
  set {
    name  = "replicas"
    value = "1"
  }
}

# EKS requires an IAM role to be explicitly authorized before an EC2 instance
# using it can register as a node — the managed node group's role gets this
# automatically, but Karpenter's separately-created node role does not. Without
# this, Karpenter-provisioned instances boot fine at the EC2/OS level but never
# actually join the cluster (found live: NodeClaim stuck on "Node not registered
# with cluster" indefinitely). Lives here, not in the eks or iam module, because
# eks can't depend on iam's node role output without creating a circular
# dependency (iam already depends on eks for the OIDC provider).
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = var.karpenter_node_role_arn
  type          = "EC2_LINUX"
}
