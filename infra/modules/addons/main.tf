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

# ArgoCD (helm_release, root bootstrap, webhook secret, its own DNS record)
# moved to modules/argocd — was stuck here because wait_for_load_balancers
# below used to depend on ArgoCD having synced the gitops-managed nginx-alb
# Ingress before the ALB Controller had anything to provision from. Now that
# nginx-alb is a Terraform resource (below) instead of gitops content, that
# cycle is gone and ArgoCD can live in its own module like everything else.

# ── ALB Ingress: the one real AWS load balancer everything shares ───────────
# Used to be applied by ArgoCD from gitops (apps/{env}/nginx-alb-ingress.yaml)
# — moved here specifically to break the cycle noted above, and because a
# from-zero cluster no longer needs ArgoCD bootstrapped just to get its own
# networking up. certificate_arn now comes directly from the global module's
# own output instead of being pasted into a YAML file by hand (that output's
# own description used to say "not wired automatically since Ingress YAML
# lives outside Terraform" — this closes that gap).
resource "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
    annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "ingress-nginx-controller"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.alb_controller, helm_release.nginx]
}

# ── Wait for the real load balancer hostname before anything reads it ───────
# aws_route53_record.app below reads the ALB Controller's real AWS ALB for
# nginx-alb's Ingress — only assigned once the ALB Controller has actually
# provisioned it. Takes real wall-clock minutes, entirely outside a single
# `terraform apply`'s control — hit this exact race on every from-zero
# rebuild so far. Polls instead of a blind sleep, same lesson already learned
# for LB *deletion* in this module's terragrunt.hcl destroy hook (Bug 34).
resource "null_resource" "wait_for_load_balancers" {
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${data.aws_region.current.name} --name ${var.cluster_name}
      echo "Waiting for nginx-alb Ingress to get a real load balancer hostname..."
      for i in $(seq 1 40); do
        ALB_HOST=$(kubectl get ingress nginx-alb -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [ -n "$ALB_HOST" ]; then
          echo "ALB ready: $ALB_HOST"
          exit 0
        fi
        echo "  not ready yet (alb='$ALB_HOST') - waiting 15s (attempt $i/40)..."
        sleep 15
      done
      echo "ERROR: load balancer never became ready after 10 minutes."
      exit 1
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [kubernetes_ingress_v1.nginx_alb]
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

# ── DNS: point the app's hostnames at the ALB (in front of Nginx) ───────────
# A separate read (not just reusing kubernetes_ingress_v1.nginx_alb's own
# attributes above) because the ALB Controller populates .status.loadBalancer
# asynchronously, well after Terraform's own create call returns — this data
# source, evaluated after null_resource.wait_for_load_balancers's poll
# succeeds, gets the real, populated value; the resource's own attribute
# wouldn't refresh mid-apply just because something else waited.
data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
  }
  depends_on = [null_resource.wait_for_load_balancers]
}

# An empty string in var.app_hostnames means "the bare apex domain" (used by
# prod, so the live site is just snapdf.bond, not prod.snapdf.bond). A CNAME
# record can never exist at a zone's apex -- that's a DNS spec rule, not an
# AWS limitation -- so that one entry needs a real A-type ALIAS record instead
# (Route53's own extension that's allowed at the apex) while every other,
# genuinely-subdomain entry (dev./staging.snapdf.bond) stays a plain CNAME
# exactly as before.
resource "aws_route53_record" "app" {
  for_each = toset(var.app_hostnames)

  zone_id = var.route53_zone_id
  name    = each.value == "" ? var.domain_name : "${each.value}.${var.domain_name}"
  type    = each.value == "" ? "A" : "CNAME"
  ttl     = each.value == "" ? null : 300
  records = each.value == "" ? null : [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]

  dynamic "alias" {
    for_each = each.value == "" ? [1] : []
    content {
      name = data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname
      # The ALB's own canonical hosted zone ID for us-east-1 -- a fixed,
      # AWS-published per-region constant for ALBs/CLBs, unrelated to (and not
      # to be confused with) var.route53_zone_id, which is this project's own
      # domain's zone.
      zone_id                = "Z35SXDOTRQ7X7K"
      evaluate_target_health = true
    }
  }
}

# KEDA, Karpenter, the whole Prometheus/Grafana/postgres-exporter stack, and
# ArgoCD itself (helm_release + root bootstrap + webhook secret + its own DNS
# record) all used to live here — moved out to their own modules
# (modules/keda, modules/karpenter, modules/observability, modules/argocd) so
# a project that only wants a subset doesn't have to drag in everything.
# ArgoCD couldn't be split out until nginx-alb became a Terraform resource
# (above) instead of gitops-applied content — this module's own
# wait_for_load_balancers/aws_route53_record.app used to depend on ArgoCD's
# root Application having already synced it, a real cycle that's gone now.

# ── DB credentials — read here too (duplicated from modules/observability's
# own copy) purely for the staging-database job below, which stayed in this
# module since it's snaPDF-specific glue, not generic reusable infra.
data "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = var.env_name == "prod" ? "snapdf-prod/db-credentials" : "snapdf/db-credentials"
}

locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.db_credentials.secret_string)
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
