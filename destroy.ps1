# snaPDF — Safe Destroy Script
# Run this instead of running terragrunt destroy directly
# It pre-cleans AWS resources that Terraform doesn't manage before destroying infra

Write-Host "=== Step 1: Connect kubectl to dev cluster ===" -ForegroundColor Cyan
aws eks update-kubeconfig --region us-east-1 --name snapdf-dev

Write-Host "=== Step 2: Delete Kubernetes LoadBalancer services and Ingresses ===" -ForegroundColor Cyan
Write-Host "    (These create real AWS load balancers — must delete before destroying VPC)"
kubectl delete svc --all -n dev 2>$null
kubectl delete ingress --all -n dev 2>$null
kubectl delete svc --all -n staging 2>$null
kubectl delete ingress --all -n staging 2>$null
kubectl delete svc -n kube-system aws-load-balancer-webhook-service 2>$null

Write-Host "=== Step 3: Wait 30 seconds for AWS to delete the load balancers ===" -ForegroundColor Cyan
Start-Sleep -Seconds 30

Write-Host "=== Step 4: Destroy all infrastructure ===" -ForegroundColor Cyan
Set-Location infra/environments/dev
terragrunt run-all destroy

Write-Host "=== Done ===" -ForegroundColor Green
