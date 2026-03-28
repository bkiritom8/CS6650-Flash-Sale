#!/bin/bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXP_DIR="${ROOT_DIR}/experiments/experiment1"
TF_DIR="${EXP_DIR}/terraform"

echo "================================================"
echo "  Experiment 1 — Deploy"
echo "  Region : $AWS_REGION"
echo "================================================"
echo ""

# ── Prerequisites check ───────────────────────────────────────────────────────
echo "--- Checking prerequisites..."
aws sts get-caller-identity > /dev/null
echo "    AWS credentials: OK"

# Verify the main platform is deployed (experiment1 attaches to its infra)
MAIN_TF="${ROOT_DIR}/terraform/main"
if [ ! -f "${MAIN_TF}/terraform.tfstate" ] || \
   ! (cd "${MAIN_TF}" && terraform output alb_dns_name > /dev/null 2>&1); then
  echo ""
  echo "ERROR: Main platform does not appear to be deployed."
  echo "Run ./scripts/deploy.sh from the repo root first."
  exit 1
fi
echo "    Main platform: OK"

# ── Go mod tidy ───────────────────────────────────────────────────────────────
echo ""
echo "--- Tidying Go modules..."
cd "${EXP_DIR}"
go mod tidy

# ── Terraform: provision ECR + ECS + ALB rule ─────────────────────────────────
echo ""
echo "--- Initialising Terraform..."
cd "${TF_DIR}"
terraform init -upgrade

echo ""
echo "--- Applying infrastructure..."
terraform apply -auto-approve

# ── Build & push Docker image ─────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE="${ECR_URL}/concert-platform-experiment1:latest"

echo ""
echo "--- Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_URL"

echo ""
echo "--- Building experiment1 image (linux/amd64)..."
docker build --platform linux/amd64 -t "$IMAGE" "${EXP_DIR}"

echo ""
echo "--- Pushing experiment1 image..."
docker push "$IMAGE"

# ── Force ECS redeployment ────────────────────────────────────────────────────
echo ""
echo "--- Forcing ECS redeployment..."
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)
aws ecs update-service \
  --cluster  "$CLUSTER" \
  --service  "$SERVICE" \
  --force-new-deployment \
  --region   "$AWS_REGION" \
  --output   text \
  --query    "service.serviceName" > /dev/null
echo "    Redeployed: $SERVICE"

# ── Wait for health ───────────────────────────────────────────────────────────
EXP1_URL=$(terraform output -raw experiment1_url)

echo ""
echo "--- Waiting for experiment1 to pass health check..."
echo -n "    experiment1 "
attempts=0
until curl -sf "${EXP1_URL}/health" > /dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ $attempts -ge 40 ]; then
    echo ""
    echo "ERROR: health check timed out after $((attempts * 15))s"
    echo "Check logs: aws logs tail /ecs/concert-platform-experiment1 --follow --region $AWS_REGION"
    exit 1
  fi
  echo -n "."
  sleep 15
done
echo " OK"

echo ""
echo "================================================"
echo "  Experiment 1 deployed!"
echo "  URL : $EXP1_URL"
echo ""
echo "  Run a quick test:"
echo "  curl -s -X POST ${EXP1_URL}/api/v1/run \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"lock_mode\":\"none\",\"db_backend\":\"mysql\",\"concurrency\":100}' | jq ."
echo "================================================"
