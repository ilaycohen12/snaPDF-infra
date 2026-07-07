locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/addons"

  # ── ALB cleanup before destroy ──────────────────────────────────────────
  before_hook "delete_load_balancers" {
    commands = ["destroy"]
    execute = [
      "powershell", "-NoProfile", "-NonInteractive", "-Command",
      <<-EOT
      Write-Host "Deleting Ingress/Service objects to trigger real ALB Controller cleanup..."
      aws eks update-kubeconfig --region us-east-1 --name snapdf-${local.env.locals.env_name} 2>$null

      kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 --timeout=30s 2>$null

      kubectl delete ingress --all --all-namespaces --ignore-not-found 2>$null
      kubectl delete svc ingress-nginx-controller -n ingress-nginx --ignore-not-found 2>$null
      kubectl delete svc argocd-server -n argocd --ignore-not-found 2>$null

      $VPC_ID = "${dependency.vpc.outputs.vpc_id}"
      Write-Host "Polling AWS for load balancers in $VPC_ID (replaces the old blind 90s sleep)..."
      $COUNT = "1"
      for ($i = 1; $i -le 20; $i++) {
        $COUNT = aws elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text 2>$null
        if (-not $COUNT) { $COUNT = "0" }
        if ($COUNT -eq "0" -or $COUNT -eq "None") {
          Write-Host "No load balancers remain in $VPC_ID."
          break
        }
        Write-Host "  $COUNT LB(s) still exist - waiting 15s (attempt $i/20)..."
        Start-Sleep -Seconds 15
      }
      if ($COUNT -ne "0" -and $COUNT -ne "None") {
        Write-Host "WARNING: $COUNT load balancer(s) still present in $VPC_ID after 5min - vpc module destroy will likely fail with DependencyViolation. Manual cleanup needed: aws elbv2 delete-load-balancer."
      }

      Start-Sleep -Seconds 10
      $sgs = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" --query "SecurityGroups[*].GroupId" --output text 2>$null
      if ($sgs) {
        foreach ($sg in ($sgs -split '\s+')) {
          if ($sg) {
            Write-Host "Deleting leftover ALB-controller security group $sg"
            aws ec2 delete-security-group --group-id $sg 2>$null
          }
        }
      }

      Write-Host "Proceeding with terraform destroy."
      exit 0
      EOT
    ]
  }
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "snapdf-dev"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "iam" {
  config_path = "../iam"

  mock_outputs = {
    alb_controller_role_arn = "arn:aws:iam::123456789012:role/snapdf-dev-alb-controller"
    eso_role_arn            = "arn:aws:iam::123456789012:role/snapdf-dev-eso"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "global" {
  config_path = "../../../global"

  mock_outputs = {
    route53_zone_id              = "Z0000000000000000000"
    acm_certificate_arn          = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    dev_wildcard_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "rds" {
  config_path = "../rds"

  mock_outputs = {
    resource_id = "db-mock00000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  env_name                           = local.env.locals.env_name
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  vpc_id                             = dependency.vpc.outputs.vpc_id
  alb_controller_role_arn            = dependency.iam.outputs.alb_controller_role_arn
  eso_role_arn                       = dependency.iam.outputs.eso_role_arn
  route53_zone_id                    = dependency.global.outputs.route53_zone_id
  acm_certificate_arn                = dependency.global.outputs.acm_certificate_arn
  additional_certificate_arns        = [dependency.global.outputs.dev_wildcard_certificate_arn]
  wildcard_hostnames                 = ["dev"]
  domain_name                        = "snapdf.bond"
  app_hostnames                      = ["dev", "staging"]
  rds_resource_id                    = dependency.rds.outputs.resource_id
}
