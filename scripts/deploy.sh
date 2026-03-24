#!/bin/bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "================================================"
echo "  Concert Ticket Platform — Deploy"
echo "  Region : $AWS_REGION"
echo "================================================"
echo ""

# ── Tidy all Go modules ───────────────────────────────────────────────────────
echo "--- Tidying Go modules..."
for svc in inventory-service booking-service queue-service; do
  echo "    go mod tidy: $svc"
  cd "${ROOT_DIR}/src/${svc}"
  go mod tidy
done

# ── Ensure scripts are executable ────────────────────────────────────────────
chmod +x "${ROOT_DIR}/scripts/deploy.sh"
chmod +x "${ROOT_DIR}/scripts/cleanup.sh"
chmod +x "${ROOT_DIR}/scripts/test-platform.sh"

# ── Terraform init + apply (provisions infra, skips if nothing changed) ───────
cd "${ROOT_DIR}/terraform/main"
echo ""
echo "--- Initialising Terraform..."
terraform init -upgrade

echo ""
echo "--- Applying infrastructure..."
terraform apply -auto-approve

# ── Collect outputs ───────────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ALB=$(terraform output -raw alb_dns_name)
INV_URL="http://${ALB}/inventory"
BK_URL="http://${ALB}/booking"
Q_URL="http://${ALB}/queue"

echo ""
echo "================================================"
echo "  ALB DNS      : $ALB"
echo "  Inventory    : $INV_URL"
echo "  Booking      : $BK_URL"
echo "  Queue        : $Q_URL"
echo "================================================"
echo ""

# ── Always rebuild and push all Docker images ─────────────────────────────────
# This ensures code changes are always deployed even when Terraform
# detects no infrastructure changes.
echo "--- Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS \
  --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

declare -A SERVICE_REPOS=(
  ["inventory-service"]="concert-inventory-service"
  ["booking-service"]="concert-booking-service"
  ["queue-service"]="concert-queue-service"
)

for svc in inventory-service booking-service queue-service; do
  REPO="${SERVICE_REPOS[$svc]}"
  IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO}:latest"
  echo ""
  echo "--- Building ${svc}..."
  docker build -t "$IMAGE" "${ROOT_DIR}/src/${svc}"
  echo "--- Pushing ${svc}..."
  docker push "$IMAGE"
done

# ── Force ECS redeployment to pull new images ─────────────────────────────────
echo ""
echo "--- Forcing ECS redeployment on all services..."

declare -A ECS_SERVICES=(
  ["concert-platform-inventory-cluster"]="concert-platform-inventory"
  ["concert-platform-booking-cluster"]="concert-platform-booking"
  ["concert-platform-queue-cluster"]="concert-platform-queue"
)

for cluster in "${!ECS_SERVICES[@]}"; do
  svc="${ECS_SERVICES[$cluster]}"
  echo "    Redeploying ${svc}..."
  aws ecs update-service \
    --cluster "$cluster" \
    --service "$svc" \
    --force-new-deployment \
    --region "$AWS_REGION" \
    --output text \
    --query "service.serviceName" > /dev/null
done

# ── Wait for all three services to be healthy ─────────────────────────────────
echo ""
echo "--- Waiting for all services to pass health checks..."
echo ""

wait_healthy() {
  local name=$1
  local url=$2
  local attempts=0
  echo -n "    $name "
  until curl -sf "${url}/health" > /dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ $attempts -ge 40 ]; then
      echo ""
      echo "ERROR: $name health check timed out after $((attempts * 15))s"
      echo "Check logs: aws logs tail /ecs/concert-platform-${name%%-service} --follow --region $AWS_REGION"
      exit 1
    fi
    echo -n "."
    sleep 15
  done
  echo " OK"
}

wait_healthy "inventory-service" "$INV_URL"
wait_healthy "booking-service"   "$BK_URL"
wait_healthy "queue-service"     "$Q_URL"

echo ""
echo "================================================"
echo "  All services healthy!"
echo "  Run smoke tests: ./scripts/test-platform.sh"
echo "================================================"