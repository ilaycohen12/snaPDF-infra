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
data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
  }
}

# ── EBS CSI Driver (Prometheus needs a real PersistentVolume) ────────────────
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = var.ebs_csi_role_arn
}

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
resource "random_password" "grafana_admin" {
  length           = 24
  special          = true
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

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "3d"
  }

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }

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
data "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = var.env_name == "prod" ? "snapdf-prod/db-credentials" : "snapdf/db-credentials"
}

locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.db_credentials.secret_string)
}

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
resource "helm_release" "monitoring_extras" {
  name       = "monitoring-extras"
  chart      = "${path.module}/charts/monitoring-extras"
  namespace  = "monitoring"
  depends_on = [helm_release.kube_prometheus_stack]
}

# ── Grafana Ingress ──────────────────────────────────────────────────────────
resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = "monitoring"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }
  spec {
    rule {
      host = "${var.grafana_hostname}.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "kube-prometheus-stack-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ── DNS: Grafana's own hostname ──────────────────────────────────────────────
resource "aws_route53_record" "grafana" {
  zone_id = var.route53_zone_id
  name    = "${var.grafana_hostname}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
}
