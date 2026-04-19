#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$AWS_REGION  = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$ROOT_DIR    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Write-Host "================================================"
Write-Host "  Concert Ticket Platform - Deploy"
Write-Host "  Region : $AWS_REGION"
Write-Host "================================================"
Write-Host ""

# ── Tidy all Go modules ───────────────────────────────────────────────────────
Write-Host "--- Tidying Go modules..."
foreach ($svc in @("inventory-service", "booking-service", "queue-service")) {
    Write-Host "    go mod tidy: $svc"
    Set-Location (Join-Path $ROOT_DIR "src\$svc")
    go mod tidy
}

# ── Terraform init + apply ────────────────────────────────────────────────────
Set-Location (Join-Path $ROOT_DIR "terraform\main")
Write-Host ""
Write-Host "--- Initialising Terraform..."
terraform init -upgrade

Write-Host ""
Write-Host "--- Applying infrastructure..."
terraform apply -auto-approve

# ── Collect outputs ───────────────────────────────────────────────────────────
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$ALB        = terraform output -raw alb_dns_name
$INV_URL    = "http://$ALB/inventory"
$BK_URL     = "http://$ALB/booking"
$Q_URL      = "http://$ALB/queue"

Write-Host ""
Write-Host "================================================"
Write-Host "  ALB DNS      : $ALB"
Write-Host "  Inventory    : $INV_URL"
Write-Host "  Booking      : $BK_URL"
Write-Host "  Queue        : $Q_URL"
Write-Host "================================================"
Write-Host ""

# ── Log in to ECR ─────────────────────────────────────────────────────────────
Write-Host "--- Logging in to ECR..."
$password = aws ecr get-login-password --region $AWS_REGION
docker login --username AWS --password $password "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# ── Build and push Docker images ──────────────────────────────────────────────
$SERVICE_REPOS = @{
    "inventory-service" = "concert-inventory-service"
    "booking-service"   = "concert-booking-service"
    "queue-service"     = "concert-queue-service"
}

foreach ($svc in @("inventory-service", "booking-service", "queue-service")) {
    $repo  = $SERVICE_REPOS[$svc]
    $image = "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/${repo}:latest"
    Write-Host ""
    Write-Host "--- Building $svc..."
    docker build --platform linux/amd64 -t $image (Join-Path $ROOT_DIR "src\$svc")
    Write-Host "--- Pushing $svc..."
    docker push $image
}

# ── Force ECS redeployment ────────────────────────────────────────────────────
Write-Host ""
Write-Host "--- Forcing ECS redeployment on all services..."

$ECS_SERVICES = @{
    "concert-platform-inventory-cluster" = "concert-platform-inventory"
    "concert-platform-booking-cluster"   = "concert-platform-booking"
    "concert-platform-queue-cluster"     = "concert-platform-queue"
}

foreach ($cluster in $ECS_SERVICES.Keys) {
    $svc = $ECS_SERVICES[$cluster]
    Write-Host "    Redeploying $svc..."
    aws ecs update-service `
        --cluster $cluster `
        --service $svc `
        --force-new-deployment `
        --region $AWS_REGION `
        --output text `
        --query "service.serviceName" | Out-Null
}

# ── Wait for all services to be healthy ───────────────────────────────────────
Write-Host ""
Write-Host "--- Waiting for all services to pass health checks..."
Write-Host ""

function Wait-Healthy {
    param(
        [string]$Name,
        [string]$Url
    )
    $attempts = 0
    Write-Host -NoNewline "    $Name "
    while ($true) {
        try {
            $resp = Invoke-WebRequest -Uri "$Url/health" -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { break }
        } catch { }

        $attempts++
        if ($attempts -ge 40) {
            Write-Host ""
            Write-Host "ERROR: $Name health check timed out after $($attempts * 15)s"
            $shortName = $Name -replace "-service$", ""
            Write-Host "Check logs: aws logs tail /ecs/concert-platform-$shortName --follow --region $AWS_REGION"
            exit 1
        }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 15
    }
    Write-Host " OK"
}

Wait-Healthy -Name "inventory-service" -Url $INV_URL
Wait-Healthy -Name "booking-service"   -Url $BK_URL
Wait-Healthy -Name "queue-service"     -Url $Q_URL

Write-Host ""
Write-Host "================================================"
Write-Host "  All services healthy!"
Write-Host "  Run smoke tests: .\scripts\test-platform.ps1"
Write-Host "================================================"