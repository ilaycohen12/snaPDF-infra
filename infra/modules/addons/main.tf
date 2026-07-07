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
  version    = "1.17.1"
  wait       = true
  timeout    = 300

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

# ── ALB Ingress: the one real AWS load balancer everything shares ───────────
resource "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
    annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/certificate-arn" = join(",", concat([var.acm_certificate_arn], var.additional_certificate_arns))
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

  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }
}

# ── DNS: point the app's hostnames at the ALB (in front of Nginx) ───────────
data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
  }
  depends_on = [null_resource.wait_for_load_balancers]
}

# ── Route53 records for app hostnames ───────────────────────────────────────
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
      name                   = data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname
      zone_id                = "Z35SXDOTRQ7X7K"
      evaluate_target_health = true
    }
  }
}

# ── Wildcard DNS per environment ─────────────────────────────────────────────
resource "aws_route53_record" "wildcard" {
  for_each = toset(var.wildcard_hostnames)

  zone_id = var.route53_zone_id
  name    = "*.${each.value}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
}

# ── DB credentials ───────────────────────────────────────────────────────────
data "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = var.env_name == "prod" ? "snapdf-prod/db-credentials" : "snapdf/db-credentials"
}

locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.db_credentials.secret_string)
}

# ── One-off: ensure the "snapdf_staging" logical database exists ────────────
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
          name  = "psql"
          image = "postgres:16-alpine"
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
