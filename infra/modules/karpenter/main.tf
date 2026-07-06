data "aws_region" "current" {}

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

# ── Fargate profile for Karpenter's own controller ──────────────────────────
# Deliberately its own namespace ("karpenter", not kube-system) — a Fargate
# profile matches by namespace, and kube-system also holds CoreDNS/kube-proxy/
# the VPC CNI, none of which can run on Fargate (kube-proxy needs host
# networking; the others are DaemonSets, which Fargate doesn't support at
# all). Scoping the profile to a namespace nothing else uses means it can
# never accidentally claim a pod that would just fail to schedule.
resource "aws_iam_role" "fargate_execution" {
  name = "${var.cluster_name}-karpenter-fargate-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fargate_execution" {
  role       = aws_iam_role.fargate_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

resource "aws_eks_fargate_profile" "karpenter" {
  cluster_name           = var.cluster_name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.fargate_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "karpenter"
  }
}

# ── Karpenter ─────────────────────────────────────────────────────────────────
# Runs on Fargate (the profile above), not the static managed node group or a
# node it manages itself — avoids the bootstrapping problem where Karpenter's
# controller would need to already be running to decide whether to evict the
# very node it's sitting on.
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  version          = "1.1.1"
  wait             = true # must be genuinely ready before we trust it to manage capacity
  timeout          = 300
  depends_on       = [aws_eks_fargate_profile.karpenter]

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

  # The chart's own default is `resources: {}` — harmless on a real EC2 node
  # (just uses whatever's free), but fatal on Fargate: Fargate sizes the
  # microVM off the pod's own resource requests, so with none set it gets
  # sized far too small to run the controller at all. Confirmed live: with no
  # requests, the controller crash-looped (Exit Code 1) with zero log output
  # ever flushed, and its own health endpoint timed out/reset under kubelet's
  # probes. 1 vCPU / 1Gi is enough for this project's node counts; limits
  # match requests since Fargate can't burst a pod past its sized capacity
  # anyway.
  set {
    name  = "controller.resources.requests.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
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

# ── EC2NodeClass + NodePool: what Karpenter is actually allowed to provision ─
# Was applied by ArgoCD from gitops (apps/{env}/karpenter-nodepool.yaml) —
# moved here so it's created automatically by the same terragrunt apply that
# installs Karpenter itself, no gitops sync required. Uses local-exec + raw
# kubectl rather than the `kubernetes_manifest` resource, same reasoning as
# ArgoCD's root bootstrap: both CRDs (EC2NodeClass, NodePool) are installed by
# helm_release.karpenter in this same apply — on a truly fresh cluster neither
# CRD exists yet when planning starts, which `kubernetes_manifest` can't
# tolerate but raw kubectl doesn't care about.
resource "null_resource" "karpenter_nodepool" {
  triggers = {
    manifest = join("\n---\n", [
      yamlencode({
        apiVersion = "karpenter.k8s.aws/v1"
        kind       = "EC2NodeClass"
        metadata = {
          name = "default"
        }
        spec = {
          amiFamily = "AL2023"
          amiSelectorTerms = [
            { alias = "al2023@latest" }
          ]
          instanceProfile = "snapdf-${var.env_name}-karpenter-node"
          subnetSelectorTerms = [
            { tags = { "karpenter.sh/discovery" = "snapdf-${var.env_name}" } }
          ]
          securityGroupSelectorTerms = [
            { tags = { "kubernetes.io/cluster/snapdf-${var.env_name}" = "owned" } }
          ]
        }
      }),
      yamlencode({
        apiVersion = "karpenter.sh/v1"
        kind       = "NodePool"
        metadata = {
          name = "default"
        }
        spec = {
          template = {
            spec = {
              requirements = [
                { key = "node.kubernetes.io/instance-type", operator = "In", values = var.node_instance_types },
                { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
                { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
              ]
              nodeClassRef = {
                group = "karpenter.k8s.aws"
                kind  = "EC2NodeClass"
                name  = "default"
              }
            }
          }
          limits = {
            cpu    = var.node_cpu_limit
            memory = var.node_memory_limit
          }
          disruption = {
            consolidationPolicy = "WhenEmptyOrUnderutilized"
            consolidateAfter    = "30s"
          }
        }
      }),
    ])
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${data.aws_region.current.name} --name ${var.cluster_name}
      cat <<'MANIFEST' | kubectl apply -f -
      ${self.triggers.manifest}
      MANIFEST
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [helm_release.karpenter]
}
