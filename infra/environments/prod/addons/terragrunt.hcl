locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")) # reads prod/env.hcl
}

include "root" {
  path = find_in_parent_folders() # inherits S3 backend + provider from infra/terragrunt.hcl
}

terraform {
  source = "../../../modules/addons" # points to infra/modules/addons

  # Delete AWS Load Balancers BEFORE terraform destroy runs.
  # ALBs are created by the ALB controller (outside Terraform state). If they're
  # not deleted before the EKS cluster is torn down, the VPC deletion will fail
  # because orphaned ALBs/security-groups still reference the VPC subnets.
  #
  # Bug 34 (04/07/2026): this hook used to only delete the ingress-nginx/argocd-server
  # *Services* and then blind `sleep 90`. Since infra #18 switched Nginx to ClusterIP,
  # the real ALB comes from the Ingress object instead - deleting only the Service
  # triggered nothing, and even when the right object was deleted, ArgoCD (still
  # running until later in this same destroy) auto-synced it back within its ~3min
  # poll window. The ALB Controller's own pods then got destroyed with the cluster
  # before AWS finished deleting the orphaned ALB, blocking VPC teardown for 69+ min.
  before_hook "delete_load_balancers" {
    commands = ["destroy"]
    execute = [
      "bash", "-c",
      <<-EOT
      echo "Deleting Ingress/Service objects to trigger real ALB Controller cleanup..."
      aws eks update-kubeconfig --region us-east-1 --name snapdf-${local.env.locals.env_name} 2>/dev/null || true

      # Stop ArgoCD reconciling before deleting anything below - it isn't destroyed
      # itself until later in this same terraform destroy run, so left running it
      # would just recreate the Ingress/Service we're about to delete.
      kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 --timeout=30s 2>/dev/null || true

      kubectl delete ingress --all --all-namespaces --ignore-not-found 2>/dev/null || true
      kubectl delete svc ingress-nginx-controller -n ingress-nginx --ignore-not-found 2>/dev/null || true
      kubectl delete svc argocd-server -n argocd --ignore-not-found 2>/dev/null || true

      VPC_ID="${dependency.vpc.outputs.vpc_id}"
      echo "Polling AWS for load balancers in $VPC_ID (replaces the old blind 90s sleep)..."
      COUNT=1
      for i in $(seq 1 20); do
        COUNT=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text 2>/dev/null)
        COUNT=$${COUNT:-0}
        if [ "$COUNT" = "0" ] || [ "$COUNT" = "None" ]; then
          echo "No load balancers remain in $VPC_ID."
          break
        fi
        echo "  $COUNT LB(s) still exist - waiting 15s (attempt $i/20)..."
        sleep 15
      done
      if [ "$COUNT" != "0" ] && [ "$COUNT" != "None" ]; then
        echo "WARNING: $COUNT load balancer(s) still present in $VPC_ID after 5min - vpc module destroy will likely fail with DependencyViolation. Manual cleanup needed: aws elbv2 delete-load-balancer."
      fi

      # ALB Controller-created security groups aren't Terraform-managed and won't be
      # cleaned up by the vpc module destroy - delete any leftover ones now that their
      # ENIs should have released along with the LB(s) above.
      sleep 10
      for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" --query "SecurityGroups[*].GroupId" --output text 2>/dev/null); do
        echo "Deleting leftover ALB-controller security group $sg"
        aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
      done

      echo "Proceeding with terraform destroy."
      EOT
    ]
  }
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "snapdf-prod"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "iam" {
  config_path = "../iam"

  mock_outputs = {
    alb_controller_role_arn       = "arn:aws:iam::123456789012:role/snapdf-prod-alb-controller"
    eso_role_arn                  = "arn:aws:iam::123456789012:role/snapdf-prod-eso"
    keda_role_arn                 = "arn:aws:iam::123456789012:role/snapdf-prod-keda"
    karpenter_controller_role_arn = "arn:aws:iam::123456789012:role/snapdf-prod-karpenter-controller"
    karpenter_node_role_arn       = "arn:aws:iam::123456789012:role/snapdf-prod-karpenter-node"
    ebs_csi_role_arn              = "arn:aws:iam::123456789012:role/snapdf-prod-ebs-csi"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "global" {
  config_path = "../../../global"

  mock_outputs = {
    route53_zone_id = "Z0000000000000000000"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  env_name                           = local.env.locals.env_name
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  vpc_id                             = dependency.vpc.outputs.vpc_id
  alb_controller_role_arn            = dependency.iam.outputs.alb_controller_role_arn
  eso_role_arn                       = dependency.iam.outputs.eso_role_arn
  keda_role_arn                      = dependency.iam.outputs.keda_role_arn
  route53_zone_id                    = dependency.global.outputs.route53_zone_id
  domain_name                        = "snapdf.bond"
  app_hostnames                      = ["prod"]
  argocd_hostname                    = "argocd-prod"
  grafana_hostname                   = "grafana-prod"
  karpenter_controller_role_arn      = dependency.iam.outputs.karpenter_controller_role_arn
  karpenter_node_role_arn            = dependency.iam.outputs.karpenter_node_role_arn
  ebs_csi_role_arn                   = dependency.iam.outputs.ebs_csi_role_arn
}
