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
# Requires kube-prometheus-stack's ServiceMonitor CRD to already exist (the
# prometheus.operator.enabled settings below make this chart create its own
# ServiceMonitor) — enforced via this module's terragrunt.hcl `dependency` on
# the observability module, not a Terraform depends_on (that only works within
# a single state; kube_prometheus_stack now lives in a different module/state).
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

  # Lets Prometheus graph real scaler activity/queue-depth decisions — turns
  # "KEDA scaled signed-worker 0->3" from an assertion into an actual panel.
  # NOTE: the chart's ServiceMonitor templates require BOTH keys true —
  # {{- if and .Values.prometheus.operator.enabled .Values.prometheus.operator.serviceMonitor.enabled }}
  # (confirmed directly from the chart source) — setting only one half (either
  # the top-level .enabled, tried first, or only .serviceMonitor.enabled, tried
  # second) silently renders nothing, no error either way.
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
