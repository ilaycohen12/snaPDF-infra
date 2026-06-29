# Run this if terragrunt destroy crashes and leaves stuck state locks
# It removes all .tflock files from the S3 state bucket

Write-Host "=== Removing stuck state locks from S3 ===" -ForegroundColor Cyan
aws s3 rm s3://projectview-tf-state-086241318869/environments/dev/ --recursive --exclude "*" --include "*.tflock"
Write-Host "=== Done — you can now run destroy again ===" -ForegroundColor Green
