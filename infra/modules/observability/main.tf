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

# ── Kubernetes Provider ───────────────────────────────────────────────────────
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

# ── DNS: reads the ALB Controller's real AWS ALB for nginx-alb's Ingress ────
# Own copy of this data source, not a shared output from the addons module —
# this module's own terragrunt.hcl declares a `dependency` on addons purely to
# enforce apply order (nginx/ALB controller/ArgoCD bootstrap must finish
# first); it doesn't need any of addons's actual outputs, since re-reading the
# same live Ingress object here is simpler than wiring a cross-module output
# for a value that's just as easy to read directly.
data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
  }
}

# ── EBS CSI Driver (Prometheus needs a real PersistentVolume) ────────────────
# Standalone aws_eks_addon here, not inside the eks module's cluster_addons
# block (like vpc-cni) — it needs iam's role ARN, and iam depends on eks for
# the OIDC provider, so eks can't depend back on iam without a cycle.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = var.ebs_csi_role_arn
}

# The cluster's existing default "gp2" StorageClass points at the old in-tree
# kubernetes.io/aws-ebs provisioner (removed from Kubernetes years ago) — PVCs
# against it can never bind, confirmed live (Prometheus's PVC sat Pending:
# "unbound immediate PersistentVolumeClaims"). gp2 is left alone (harmless,
# not marked default) — this new gp3 class uses the real CSI provisioner and
# is what Prometheus's values below explicitly requests.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

# ── Observability: Prometheus + Grafana ──────────────────────────────────────
# One chart bundles the whole stack: Prometheus Operator (watches ServiceMonitor
# CRDs), Prometheus itself (scrapes /metrics on a timer, stores history),
# node-exporter (host stats, one per node), kube-state-metrics (k8s object
# state), and Grafana (dashboards, queries Prometheus via PromQL). Entirely
# in-cluster — no AWS API calls, no IRSA role needed, unlike every other addon.
# Real generated admin password — the chart's own default ("prom-operator") is
# a fixed, publicly documented string, unsafe to leave on anything internet-
# reachable. Stored in Secrets Manager, same pattern as every other credential
# in this project.
resource "random_password" "grafana_admin" {
  length  = 24
  special = true
  # Avoid characters that are awkward in shells/URLs when someone copy-pastes
  # this to log in — still a large enough character set to be a strong password.
  override_special = "!#%&*-_=+"
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "${var.env_name == "prod" ? "snapdf-prod" : "snapdf"}/grafana-admin-password"
  description             = "Grafana admin password for the ${var.env_name} cluster — login at admin / this value"
  recovery_window_in_days = 0

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = random_password.grafana_admin.result
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  version          = "58.2.1"
  create_namespace = true
  wait             = false
  depends_on       = [kubernetes_storage_class.gp3]

  # Short retention + small volume — cost-conscious demo sizing, not a
  # production retention policy.
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "3d"
  }

  # By default this Prometheus only scrapes ServiceMonitors carrying the label
  # release: kube-prometheus-stack — meant to stop one Prometheus in a shared
  # cluster from accidentally scraping unrelated tenants' ServiceMonitors.
  # This is a single-tenant dev/prod cluster, not shared — relaxed to match
  # every ServiceMonitor cluster-wide (an empty, non-nil selector means "all"
  # to the Prometheus Operator) so KEDA's and postgres-exporter's own
  # ServiceMonitors don't each need a matching label added by hand.
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  # set_sensitive (not set) — keeps the real password out of plan/apply output,
  # same reasoning as every other credential handled in this project.
  set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }

  # Explicit, not left to the "is-default-class" annotation — makes the
  # dependency on the real CSI-backed class obvious from the values alone.
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = kubernetes_storage_class.gp3.metadata[0].name
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "10Gi"
  }

  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "grafana.resources.requests.cpu"
    value = "50m"
  }

  set {
    name  = "grafana.resources.requests.memory"
    value = "128Mi"
  }
}

# ── Postgres Exporter — real business metrics (users, conversions) ─────────
# Bridges the gap Prometheus can't cross on its own: nothing exposes "how many
# users" or "how many conversions" as a metric, because that data only exists
# as plain rows in Postgres. This runs a few SQL queries on a timer and
# re-exposes the results as normal Prometheus metrics, same shape as every
# other exporter (node-exporter for hosts, kube-state-metrics for k8s objects,
# this one for snapdf's own business data). Read-only against the existing DB
# — no schema or app code changes.
data "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = var.env_name == "prod" ? "snapdf-prod/db-credentials" : "snapdf/db-credentials"
}

locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.db_credentials.secret_string)
}

# Custom queries file for postgres_exporter (--extend.query-path) — each
# top-level key becomes a metric namespace, e.g. snapdf_users_total's "count"
# column becomes the metric pg_snapdf_users_total_count.
resource "kubernetes_config_map" "postgres_exporter_queries" {
  metadata {
    name      = "postgres-exporter-queries"
    namespace = "monitoring"
  }

  data = {
    "queries.yaml" = <<-EOT
      snapdf_users_total:
        query: "SELECT COUNT(*) as count FROM users"
        metrics:
          - count:
              usage: "GAUGE"
              description: "Total registered users"

      snapdf_free_jobs_by_status:
        query: "SELECT status, COUNT(*) as count FROM free_jobs GROUP BY status"
        metrics:
          - status:
              usage: "LABEL"
              description: "Job status"
          - count:
              usage: "GAUGE"
              description: "Free-tier conversion jobs by status"

      snapdf_signed_jobs_by_status:
        query: "SELECT status, COUNT(*) as count FROM signed_jobs GROUP BY status"
        metrics:
          - status:
              usage: "LABEL"
              description: "Job status"
          - count:
              usage: "GAUGE"
              description: "Signed-tier conversion jobs by status"
    EOT
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "postgres_exporter" {
  name             = "postgres-exporter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-postgres-exporter"
  namespace        = "monitoring"
  create_namespace = true
  wait             = false
  depends_on       = [helm_release.kube_prometheus_stack, kubernetes_config_map.postgres_exporter_queries]

  set {
    name  = "config.datasource.host"
    value = local.db_creds.host
  }

  set {
    name  = "config.datasource.database"
    value = "snapdf"
  }

  set {
    name  = "config.datasource.sslmode"
    value = "require"
  }

  # set_sensitive — reuses the exact credential this project already manages
  # in Secrets Manager, no new secret created.
  set_sensitive {
    name  = "config.datasource.user"
    value = local.db_creds.username
  }

  set_sensitive {
    name  = "config.datasource.password"
    value = local.db_creds.password
  }

  set {
    name  = "serviceMonitor.enabled"
    value = "true"
  }

  set {
    # extraArgs is nested under config in this chart's actual schema
    # (confirmed from chart source) — a bare top-level extraArgs is silently
    # ignored, no error, same "set doesn't validate" lesson as Bug 24/34.
    name  = "config.extraArgs[0]"
    value = "--extend.query-path=/etc/postgres-exporter-queries/queries.yaml"
  }

  set {
    name  = "extraVolumes[0].name"
    value = "custom-queries"
  }

  set {
    name  = "extraVolumes[0].configMap.name"
    value = kubernetes_config_map.postgres_exporter_queries.metadata[0].name
  }

  set {
    name  = "extraVolumeMounts[0].name"
    value = "custom-queries"
  }

  set {
    name  = "extraVolumeMounts[0].mountPath"
    value = "/etc/postgres-exporter-queries"
  }
}

# ── Custom ServiceMonitors + Grafana dashboards ──────────────────────────────
# A dedicated local chart, not folded into kube-prometheus-stack's own values
# and not a bare standalone ConfigMap either — mirrors the "platform chart ->
# application chart" split (kube-prometheus-stack installs Prometheus/Grafana;
# this chart holds app-level ServiceMonitors + dashboards on top of it).
resource "helm_release" "monitoring_extras" {
  name       = "monitoring-extras"
  chart      = "${path.module}/charts/monitoring-extras"
  namespace  = "monitoring"
  depends_on = [helm_release.kube_prometheus_stack]
}

# Grafana's Ingress is routed through Nginx (kubernetes.io/ingress.class:
# nginx), not the ALB controller directly — the ALB IngressGroup path hit an
# unresolved bug where Grafana's rule never got merged onto the shared ALB
# (Bug 34). Reuses the exact same ALB hostname the app's own Route53 record
# points at — Grafana's traffic reaches the identical physical ALB, just via
# Nginx's internal host-based routing instead of a second ALB-level rule.
resource "aws_route53_record" "grafana" {
  zone_id = var.route53_zone_id
  name    = "${var.grafana_hostname}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
}
