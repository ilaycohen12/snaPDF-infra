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

# ── Kubernetes Provider ───────────────────────────────────────────────────────
# Same auth as the helm provider above — needed to read the Nginx/ArgoCD Service
# objects directly, so we can find the AWS load balancer hostname Kubernetes
# already created for them, without hardcoding or guessing it.
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

# ── ALB Ingress Controller ────────────────────────────────────────────────────
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  # Bumped from 1.7.1 (app v2.7.1, from Phase 4) to the newest version still on
  # the v2.x app line (v3.x has bigger breaking-change risk) — root-caused a
  # cross-namespace IngressGroup bug where Grafana's Ingress (monitoring ns)
  # never got its rule added to the shared ALB with nginx-alb (ingress-nginx ns).
  version = "1.17.1"
  wait    = true # must be ready before other charts trigger its webhook
  timeout = 300

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "region"
    value = data.aws_region.current.name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.alb_controller_role_arn
  }
}

# ── External Secrets Operator ─────────────────────────────────────────────────
resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  version          = "0.9.11"
  create_namespace = true
  wait             = false
  depends_on       = [helm_release.alb_controller]

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.eso_role_arn
  }
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "6.7.3"
  create_namespace = true
  wait             = false
  depends_on       = [helm_release.alb_controller]

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }
}

# ── Nginx Ingress Controller ──────────────────────────────────────────────────
# controller.service.type is ClusterIP (not the chart's default LoadBalancer) —
# Nginx no longer creates its own AWS load balancer. Real internet traffic now
# arrives via the ALB Ingress below instead (infra #18).
resource "helm_release" "nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  version          = "4.10.1"
  create_namespace = true
  wait             = false
  depends_on       = [helm_release.alb_controller]

  set {
    name  = "controller.service.type"
    value = "ClusterIP"
  }

  # Disabled: the admission-patch Job can't schedule on small clusters (pod limit)
  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }
}

# ── DNS: point real hostnames at the ALB (in front of Nginx) and ArgoCD's LB ──
# Reads the actual LB hostname Kubernetes/the ALB Controller already assigned,
# rather than hardcoding or guessing the AWS-generated name. The app hostnames
# read from the ALB Ingress's status (not Nginx's Service — it's ClusterIP now,
# it has no load balancer of its own to read a hostname from).
data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
  }
}

data "kubernetes_service" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
  depends_on = [helm_release.argocd]
}

resource "aws_route53_record" "app" {
  for_each = toset(var.app_hostnames)

  zone_id = var.route53_zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
}

resource "aws_route53_record" "argocd" {
  zone_id = var.route53_zone_id
  name    = "${var.argocd_hostname}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_service.argocd.status[0].load_balancer[0].ingress[0].hostname]
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
  # Also depends on kube_prometheus_stack (Phase 5): prometheus.operator.enabled
  # below makes this chart create its own ServiceMonitor, which requires the
  # ServiceMonitor CRD to already exist — that CRD ships with the prometheus
  # Operator subchart, not with KEDA itself.
  depends_on = [helm_release.alb_controller, helm_release.kube_prometheus_stack]

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

# ── Karpenter ─────────────────────────────────────────────────────────────────
# Node autoscaling — installed alongside the existing managed node group for now
# (Phase 6, step 2 of 5). The managed node group isn't shrunk until Karpenter is
# verified working end-to-end.
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "kube-system"
  version          = "1.1.1"
  wait             = true # must be genuinely ready before we trust it to manage capacity
  timeout          = 300
  depends_on       = [helm_release.alb_controller]

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
}

# ── EBS CSI Driver (Phase 5 — Prometheus needs a real PersistentVolume) ──────
# Standalone aws_eks_addon here, not inside the eks module's cluster_addons
# block (like vpc-cni) — it needs iam's role ARN, and iam depends on eks for
# the OIDC provider, so eks can't depend back on iam without a cycle. Same
# reasoning as Karpenter's access entry living here instead of eks/iam.
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
# is what Prometheus's values.yaml below explicitly requests.
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

# ── Observability: Prometheus + Grafana (Phase 5) ────────────────────────────
# One chart bundles the whole stack: Prometheus Operator (watches ServiceMonitor
# CRDs), Prometheus itself (scrapes /metrics on a timer, stores history),
# node-exporter (host stats, one per node), kube-state-metrics (k8s object
# state), and Grafana (dashboards, queries Prometheus via PromQL). Entirely
# in-cluster — no AWS API calls, no IRSA role needed, unlike every other addon.
# Real generated admin password — the chart's own default ("prom-operator") is
# a fixed, publicly documented string, unsafe to leave on anything internet-
# reachable. Stored in Secrets Manager, same pattern as every other credential
# in this project (snapdf/db-credentials, snapdf/jwt-secret, etc.) — not
# synced via ESO since Grafana is an addon, not an app pod reading env vars.
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
  depends_on       = [helm_release.alb_controller, kubernetes_storage_class.gp3]

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

# ── One-off: ensure the "snapdf_staging" logical database exists ────────────
# Terraform only manages the RDS *instance* + its one default database
# (the `rds` module's var.db_name) — "snapdf_staging" is a second logical
# database living on that same instance (Bug 31, 02/07/2026), originally
# created once by hand via psql. A from-scratch RDS instance never has it,
# and this was hit again on the 04/07/2026 full-VPC rebuild (Bug 37).
# RDS is private (publicly_accessible = false, reachable only from EKS
# worker nodes), so a Terraform `postgresql` provider connecting from
# wherever `terraform apply` runs isn't an option — this runs as its own
# self-contained Job pod on a worker node instead, using the exact same
# `local.db_creds` this module's postgres_exporter above already reads
# (kept fresh by the `rds` module's new secret-sync resource). Keyed to
# var.rds_resource_id (the instance's internal ID, not its identifier) so
# it only actually re-runs when the RDS instance is genuinely new, not on
# every ordinary apply.
resource "kubernetes_job_v1" "ensure_staging_database" {
  count = var.env_name == "dev" && var.rds_resource_id != "" ? 1 : 0

  metadata {
    name      = "ensure-staging-database-${lower(var.rds_resource_id)}"
    namespace = "default"
  }

  spec {
    backoff_limit = 2
    template {
      metadata {
        name = "ensure-staging-database"
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "psql"
          image   = "postgres:16-alpine"
          command = ["sh", "-c", <<-EOT
            set -e
            EXISTS=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='snapdf_staging'")
            if [ "$EXISTS" != "1" ]; then
              echo "snapdf_staging missing, creating..."
              psql -c "CREATE DATABASE snapdf_staging"
            else
              echo "snapdf_staging already exists, nothing to do."
            fi
          EOT
          ]
          env {
            name  = "PGHOST"
            value = local.db_creds.host
          }
          env {
            name  = "PGUSER"
            value = local.db_creds.username
          }
          env {
            name  = "PGPASSWORD"
            value = local.db_creds.password
          }
          env {
            name  = "PGDATABASE"
            value = "snapdf"
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "3m"
  }
}

# Grafana's Ingress is routed through Nginx now (kubernetes.io/ingress.class:
# nginx), not the ALB controller directly — the ALB IngressGroup path hit an
# unresolved bug where Grafana's rule never got merged onto the shared ALB.
# Since Nginx-class Ingresses don't get their own status.loadBalancer hostname
# (only the ALB controller populates that), this reuses the exact same ALB
# hostname aws_route53_record.app already points at — Grafana's traffic
# reaches the identical physical ALB, just via Nginx's internal host-based
# routing instead of a second ALB-level rule.
resource "aws_route53_record" "grafana" {
  zone_id = var.route53_zone_id
  name    = "${var.grafana_hostname}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
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
