# snaPDF - Safe Destroy Script
# Pre-cleans AWS resources Terraform cannot manage, then destroys infra
# Uses --lock=false to prevent stuck state locks on DNS failure

param(
    [switch]$SkipK8s  # pass -SkipK8s if cluster is already gone
)

$REGION = "us-east-1"
$CLUSTER = "snapdf-dev"
$VPC_NAME = "snapdf-dev-vpc"

# ── Step 1: kubectl cleanup ──────────────────────────────────────────────────
if (-not $SkipK8s) {
    Write-Host "`n=== Step 1: Delete Kubernetes services and ingresses ===" -ForegroundColor Cyan
    aws eks update-kubeconfig --region $REGION --name $CLUSTER 2>$null
    if ($LASTEXITCODE -eq 0) {
        kubectl delete svc --all -n dev 2>$null
        kubectl delete ingress --all -n dev 2>$null
        kubectl delete svc --all -n staging 2>$null
        kubectl delete ingress --all -n staging 2>$null
        kubectl delete svc --all -n argocd 2>$null
        kubectl delete ingress --all -n argocd 2>$null
        kubectl delete svc --all -n keda 2>$null
        kubectl delete svc --all -n external-secrets 2>$null
        Write-Host "    Done."
    } else {
        Write-Host "    Cluster not reachable - skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "`n=== Step 1: Skipped (k8s already gone) ===" -ForegroundColor Yellow
}

# ── Step 2: Get VPC ID ───────────────────────────────────────────────────────
Write-Host "`n=== Step 2: Look up VPC ===" -ForegroundColor Cyan
$VPC_ID = aws ec2 describe-vpcs `
    --filters "Name=tag:Name,Values=$VPC_NAME" `
    --query "Vpcs[0].VpcId" `
    --output text

if ($VPC_ID -eq "None" -or [string]::IsNullOrEmpty($VPC_ID)) {
    Write-Host "    VPC not found - already destroyed. Skipping VPC cleanup." -ForegroundColor Yellow
} else {
    Write-Host "    VPC: $VPC_ID"

    # ── Step 3: Wait for load balancers ─────────────────────────────────────
    Write-Host "`n=== Step 3: Wait for AWS load balancers to be deleted ===" -ForegroundColor Cyan
    $attempts = 0
    do {
        $lbCount = aws elbv2 describe-load-balancers `
            --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" `
            --output text
        if ($lbCount -ne "0") {
            Write-Host "    $lbCount LB(s) still exist - waiting 15s..."
            Start-Sleep -Seconds 15
        }
        $attempts++
    } while ($lbCount -ne "0" -and $attempts -lt 16)

    # ── Step 4: Delete all ENIs in the VPC ──────────────────────────────────
    Write-Host "`n=== Step 4: Delete all network interfaces (ENIs) in the VPC ===" -ForegroundColor Cyan
    $enis = aws ec2 describe-network-interfaces `
        --filters "Name=vpc-id,Values=$VPC_ID" `
        --query "NetworkInterfaces[*]" `
        --output json | ConvertFrom-Json

    if ($enis.Count -eq 0) {
        Write-Host "    No ENIs found."
    } else {
        Write-Host "    Found $($enis.Count) ENI(s) - detaching and deleting..."
        foreach ($eni in $enis) {
            $eniId = $eni.NetworkInterfaceId
            if ($eni.Attachment -and $eni.Attachment.AttachmentId) {
                aws ec2 detach-network-interface `
                    --attachment-id $eni.Attachment.AttachmentId `
                    --force 2>$null
            }
        }
        Write-Host "    Waiting 10s for detachments..."
        Start-Sleep -Seconds 10
        foreach ($eni in $enis) {
            $eniId = $eni.NetworkInterfaceId
            Write-Host "    Deleting $eniId"
            aws ec2 delete-network-interface --network-interface-id $eniId 2>$null
        }
    }

    # ── Step 5a: Delete leftover security groups ─────────────────────────────
    Write-Host "`n=== Step 5a: Delete leftover security groups ===" -ForegroundColor Cyan
    $sgs = aws ec2 describe-security-groups `
        --filters "Name=vpc-id,Values=$VPC_ID" `
        --query "SecurityGroups[?GroupName!='default'].GroupId" `
        --output json | ConvertFrom-Json
    foreach ($sg in $sgs) {
        Write-Host "    Deleting security group $sg"
        aws ec2 delete-security-group --group-id $sg 2>$null
    }

    # ── Step 5b: Delete all subnets manually ─────────────────────────────────
    Write-Host "`n=== Step 5b: Delete subnets ===" -ForegroundColor Cyan
    $subnets = aws ec2 describe-subnets `
        --filters "Name=vpc-id,Values=$VPC_ID" `
        --query "Subnets[*].SubnetId" `
        --output json | ConvertFrom-Json

    if ($subnets.Count -eq 0) {
        Write-Host "    No subnets found."
    } else {
        foreach ($subnet in $subnets) {
            Write-Host "    Deleting subnet $subnet"
            aws ec2 delete-subnet --subnet-id $subnet 2>$null
        }
    }
}

# ── Step 6: Destroy ──────────────────────────────────────────────────────────
Write-Host "`n=== Step 6: Destroy all infrastructure ===" -ForegroundColor Cyan
Write-Host "    Using --lock=false to prevent stuck locks on DNS failure"
Set-Location infra/environments/dev
terragrunt run-all destroy --lock=false

Write-Host "`n=== Done ===" -ForegroundColor Green
