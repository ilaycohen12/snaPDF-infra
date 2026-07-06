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
# Needed to read the shared nginx-alb Ingress's own status (its own copy, same
# object addons's module already created and waited for — enforced via this
# module's terragrunt.hcl `dependencies` on addons, not a Terraform depends_on
# that can't cross module/state boundaries).
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
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
  # so it only picks up Ingresses carrying this legacy annotation instead.
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
#
# directory.recurse = true — added when apps/{env} was reorganized into
# subfolders (bootstrap/, plus nginx-alb/grafana/karpenter content that moved
# to Terraform entirely). Without this, ArgoCD only reads files directly in
# apps/{env}, not subfolders — a silent prune, not an error, if left unset.
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
          directory = {
            recurse = true
          }
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

# ── DNS: ArgoCD's own hostname, shares the same ALB as everything else ──────
resource "aws_route53_record" "argocd" {
  zone_id = var.route53_zone_id
  name    = "${var.argocd_hostname}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.nginx_alb.status[0].load_balancer[0].ingress[0].hostname]
}
