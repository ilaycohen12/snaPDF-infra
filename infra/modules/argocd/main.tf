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

# ── GitHub Provider ───────────────────────────────────────────────────────────
data "aws_secretsmanager_secret_version" "github_pat" {
  secret_id = var.github_pat_secret_arn
}

provider "github" {
  token = data.aws_secretsmanager_secret_version.github_pat.secret_string
  owner = "ilaycohen12"
}

data "kubernetes_ingress_v1" "nginx_alb" {
  metadata {
    name      = "nginx-alb"
    namespace = "ingress-nginx"
  }
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────
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

# ── GitHub OAuth for ArgoCD SSO (via Dex), stored for durability ────────────
resource "aws_secretsmanager_secret" "github_oauth" {
  name                    = var.env_name == "prod" ? "snapdf-prod/argocd-github-oauth" : "snapdf/argocd-github-oauth"
  description             = "GitHub OAuth App credentials (Dex connector) for ArgoCD SSO on the ${var.env_name} cluster"
  recovery_window_in_days = 0

  tags = { Environment = var.env_name, ManagedBy = "terragrunt" }
}

resource "aws_secretsmanager_secret_version" "github_oauth" {
  secret_id = aws_secretsmanager_secret.github_oauth.id
  secret_string = jsonencode({
    client_id     = var.github_oauth_client_id
    client_secret = var.github_oauth_client_secret
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── GitHub webhook, kept in sync with the secret above ───────────────────────
resource "github_repository_webhook" "argocd" {
  repository = "snaPDF-gitops"

  configuration {
    url          = "https://${var.argocd_hostname}.${var.domain_name}/api/webhook"
    content_type = "json"
    insecure_ssl = true
    secret       = random_password.argocd_webhook.result
  }

  events = ["push"]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "6.7.3"
  create_namespace = true
  wait             = false

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

  set {
    name  = "server.ingress.annotations.kubernetes\\.io/ingress\\.class"
    value = "nginx"
  }

  set_sensitive {
    name  = "configs.secret.githubSecret"
    value = random_password.argocd_webhook.result
  }

  # ── SSO: GitHub login via Dex, restricted by RBAC ──────────────────────────
  set {
    name  = "configs.cm.url"
    value = "https://${var.argocd_hostname}.${var.domain_name}"
  }

  set {
    name  = "dex.enabled"
    value = "true"
  }

  set {
    name = "configs.cm.dex\\.config"
    value = yamlencode({
      connectors = [{
        type = "github"
        id   = "github"
        name = "GitHub"
        config = {
          clientID     = var.github_oauth_client_id
          clientSecret = "$dex.github.clientSecret"
          orgs         = []
          useLoginAsID = true
        }
      }]
    })
  }

  set_sensitive {
    name  = "configs.secret.extra.dex\\.github\\.clientSecret"
    value = var.github_oauth_client_secret
  }

  set {
    name  = "configs.rbac.policy\\.default"
    value = ""
  }

  set {
    name  = "configs.rbac.policy\\.csv"
    value = "g\\, ${var.sso_github_username}\\, role:admin"
  }
}

# ── Bootstrap ArgoCD's root Application ──────────────────────────────────────
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
