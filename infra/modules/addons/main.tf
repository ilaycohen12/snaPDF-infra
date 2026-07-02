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
  version    = "1.7.1"
  wait       = true    # must be ready before other charts trigger its webhook
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
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # Disabled: the admission-patch Job can't schedule on small clusters (pod limit)
  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }
}

# ── DNS: point real hostnames at the Nginx and ArgoCD load balancers ──────────
# Reads the actual LB hostname Kubernetes already assigned to each Service,
# rather than hardcoding or guessing the AWS-generated name.
data "kubernetes_service" "nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
  depends_on = [helm_release.nginx]
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
  records = [data.kubernetes_service.nginx.status[0].load_balancer[0].ingress[0].hostname]
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
  depends_on       = [helm_release.alb_controller]

  set {
    name  = "podIdentity.aws.irsa.enabled"
    value = "true"
  }

  set {
    name  = "podIdentity.aws.irsa.roleArn"
    value = var.keda_role_arn
  }
}
