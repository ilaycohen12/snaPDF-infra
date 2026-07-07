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

# ── KEDA ──────────────────────────────────────────────────────────────────────
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  version          = "2.13.1"
  create_namespace = true
  wait             = false

  set {
    name  = "podIdentity.aws.irsa.enabled"
    value = "true"
  }

  set {
    name  = "podIdentity.aws.irsa.roleArn"
    value = var.keda_role_arn
  }

  set {
    name  = "prometheus.operator.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.operator.serviceMonitor.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.metricServer.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.metricServer.serviceMonitor.enabled"
    value = "true"
  }
}
