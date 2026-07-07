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
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  version          = "1.1.1"
  wait             = true
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

  set {
    name  = "replicas"
    value = "1"
  }

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

# ── EKS access entry for Karpenter-provisioned nodes ────────────────────────
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = var.karpenter_node_role_arn
  type          = "EC2_LINUX"
}

# ── EC2NodeClass + NodePool: what Karpenter is actually allowed to provision ─
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
