#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ROOT_DIR = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Write-Host "================================================"
Write-Host "  Concert Ticket Platform Cleanup"
Write-Host "  This will destroy ALL AWS resources:"
Write-Host "    VPC, ALB, ECS (3 services), RDS, DynamoDB,"
Write-Host "    ECR (3 repos), CloudWatch log groups"
Write-Host "================================================"
Write-Host ""

$confirm = Read-Host "Are you sure? Type 'yes' to confirm"
if ($confirm -ne "yes") {
    Write-Host "Aborted."
    exit 0
}

Set-Location (Join-Path $ROOT_DIR "terraform\main")
terraform destroy -auto-approve

Write-Host ""
Write-Host "Done. All AWS resources destroyed."
Write-Host "(NAT Gateway, RDS, and ECS charges have stopped.)"