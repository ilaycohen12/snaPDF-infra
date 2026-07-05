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
# infra #25: GitHub -> ArgoCD webhook, so a push reaches ArgoCD instantly instead
# of waiting out its default ~180s poll interval (gap found during the rollback
# drill). This secret is what ArgoCD uses to validate that an incoming webhook
# payload's signature really came from GitHub -- the argo-cd Helm chart's
# configs.secret.githubSecret value populates the exact field ArgoCD checks.
# The other half -- actually registering the webhook on the snaPDF-gitops repo
# -- is done once via `gh api`, not Terraform: adding a whole GitHub provider
# (+ its own PAT credential) for one webhook per environment isn't proportionate.
resource "random_password" "argocd_webhook" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "argocd_webhook" {
  name                    = var.env_name == "prod" ? "snapdf-prod/argocd-webhook-secret" : "snapdf/argocd-webhook-secret"
  description             = "Shared secret ArgoCD uses to validate incoming GitHub webhook payloads for the ${var.env_name} cluster"
  recovery_window_in_days = 0

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_secretsmanager_secret_version" "argocd_webhook" {
  secret_id     = aws_secretsmanager_secret.argocd_webhook.id
  secret_string = random_password.argocd_webhook.result
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "6.7.3"
  create_namespace = true
  wait             = false
  depends_on       = [helm_release.alb_controller, helm_release.nginx]

  # infra #26: ArgoCD used to be its own type: LoadBalancer Service, creating a
  # second, dedicated NLB per environment alongside the one ALB everything else
  # shares via Nginx. Now ClusterIP + an Ingress below, routed through the same
  # shared Nginx/ALB as api/auth/Grafana — one load balancer per environment,
  # not two. Confirmed against the actual chart source (argo-cd 6.7.3) before
  # writing these — `server.insecure` isn't a real top-level value in this
  # chart version, it only exists via configs.params; the chart's own
  # server-ingress.yaml template reads that exact key to decide which Service
  # port (http vs https) to point the Ingress at.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "server.ingress.enabled"
    value = "true"
  }

  set {
    name  = "server.ingress.hostname"
    value = "${var.argocd_hostname}.${var.domain_name}"
  }

  # NOT setting nginx.ingress.kubernetes.io/backend-protocol=GRPC here,
  # deliberately, despite ArgoCD's server multiplexing its web UI and the
  # `argocd` CLI's gRPC API on the same port — tried it live, it broke the web
  # UI. That annotation makes nginx proxy EVERY request through this Ingress
  # as raw gRPC, including plain browser page loads — a bare `HEAD /` isn't
  # gRPC-framed, so the backend resets the connection (confirmed live: nginx's
  # own error log showed "recv() failed (104: Connection reset by peer) ...
  # upstream: grpc://..." for an ordinary HEAD request). Serving plain
  # HTTP/HTTPS instead (like every other Ingress here) means the web UI just
  # works; the `argocd` CLI needs `--grpc-web` (translates gRPC calls over
  # regular HTTP/1.1) since raw unary/streaming gRPC isn't supported through
  # this Ingress — that's ArgoCD's own documented workaround for exactly this
  # class of ingress, not a workaround invented here.

  # No ingressClassName set (spec.ingressClassName) — the nginx controller
  # here runs with --ingress-class=nginx and no --watch-ingress-without-class,
  # so it only picks up Ingresses carrying this legacy annotation instead
  # (confirmed: api-dev/auth-dev/Grafana's Ingress objects all use this same
  # annotation, none set ingressClassName — this one silently went unpicked-up
  # by nginx without it, live 404 despite Terraform reporting apply success).
  set {
    name  = "server.ingress.annotations.kubernetes\\.io/ingress\\.class"
    value = "nginx"
  }

  set_sensitive {
    name  = "configs.secret.githubSecret"
    value = random_password.argocd_webhook.result
  }
}

# ── Bootstrap ArgoCD's root Application (infra #17) ──────────────────────────
# Previously the one remaining manual step in this entire system: someone had
# to remember to run `kubectl apply -f infra/bootstrap/root-app{,-prod}.yaml`
# by hand after every fresh cluster stand-up, using the RIGHT file for the
# RIGHT cluster. Got this wrong for real on 04/07/2026 — applied dev's
# manifest (path: apps/dev) to prod, which briefly ran dev/staging workloads
# inside the prod cluster (cleaned up by hand; see documentation.md).
#
# Automated here by inlining the manifest and picking the path by
# var.env_name, so there's no separate file to remember or mismatch.
# Uses local-exec + raw kubectl rather than the `kubernetes_manifest`
# resource: that resource needs to resolve the target CRD's schema at plan
# time, and ArgoCD's own `Application` CRD is installed by helm_release.argocd
# in this SAME apply — on a truly fresh cluster the CRD doesn't exist yet when
# planning starts, which `depends_on` alone doesn't fix for that resource type.
# Raw kubectl has no such restriction.
resource "null_resource" "argocd_root_bootstrap" {
  triggers = {
    manifest = yamlencode({
      apiVersion = "argoproj.io/v1alpha1"
      kind       = "Application"
      metadata = {
        name       = "root"
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
      }
      spec = {
        project = "default"
        source = {
          repoURL        = "https://github.com/ilaycohen12/snaPDF-gitops.git"
          targetRevision = "HEAD"
          path           = var.env_name == "prod" ? "apps/prod" : "apps/dev"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      }
    })
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

  depends_on = [helm_release.argocd]
}

# ── Wait for the real load balancer hostname before anything reads it ───────
# aws_route53_record.app/.argocd/.grafana below all read the ALB Controller's
# real AWS ALB for nginx-alb's Ingress — only created once ArgoCD, bootstrapped
# above, has actually synced it. Takes real wall-clock minutes, entirely
# outside a single `terraform apply`'s control — hit this exact race on every
# from-zero rebuild so far (03/07, and twice more on 04/07/2026 for dev and
# prod). Polls instead of a blind sleep, same lesson already learned for LB
# *deletion* in this module's terragrunt.hcl destroy hook (Bug 34).
# infra #26: used to also wait for argocd-server's own LoadBalancer Service —
# removed, ArgoCD shares this same ALB now instead of provisioning its own.
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

  depends_on = [null_resource.argocd_root_bootstrap]
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

resource "aws_route53_record" "argocd" {
  zone_id = var.route53_zone_id
  name    = "${var.argocd_hostname}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  # infra #26: was data.kubernetes_service.argocd's own LoadBalancer status —
  # ArgoCD no longer has its own LB, it shares the same ALB as everything else.
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
}

# KEDA, Karpenter, and the whole Prometheus/Grafana/postgres-exporter stack
# used to live here — moved out to their own modules (modules/keda,
# modules/karpenter, modules/observability) so a project that only wants a
# subset doesn't have to drag in everything. ArgoCD (helm_release + root
# bootstrap above) stays here deliberately, not split out: this module's own
# wait_for_load_balancers/aws_route53_record.app below depend on ArgoCD's root
# Application having already synced the gitops-managed nginx-alb Ingress
# itself — moving ArgoCD to a separate module would create a real dependency
# cycle (core needs ArgoCD bootstrapped; a separate ArgoCD module would need
# core's ALB ready). Discovered this while doing the split, not a design
# choice made in advance.

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
