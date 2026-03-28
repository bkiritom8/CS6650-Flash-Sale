#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXP_DIR="${ROOT_DIR}/experiments/experiment1"
TF_DIR="${EXP_DIR}/terraform"

SERVICE_NAME="concert-platform"
REGION="us-east-1"
ECR_REPO="${SERVICE_NAME}-experiment1"
ECS_CLUSTER="${SERVICE_NAME}-experiment1-cluster"
ECS_SERVICE="${SERVICE_NAME}-experiment1"

echo "================================================"
echo "  Experiment 1 — Cleanup"
echo "  This will destroy experiment1 AWS resources:"
echo "    ECR repo, ECS cluster/service/task,"
echo "    ALB target group + listener rule,"
echo "    CloudWatch log group"
echo "  (Main platform infra is NOT affected)"
echo "================================================"
echo ""
read -rp "Are you sure? Type 'yes' to confirm: " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# ── 1. Scale ECS service to 0 so tasks drain before destroy ──────────────────
echo ""
echo ">> Scaling ECS service to 0..."
if aws ecs describe-services \
     --cluster "${ECS_CLUSTER}" \
     --services "${ECS_SERVICE}" \
     --region "${REGION}" \
     --query "services[0].status" --output text 2>/dev/null | grep -q "ACTIVE"; then
  aws ecs update-service \
    --cluster "${ECS_CLUSTER}" \
    --service "${ECS_SERVICE}" \
    --desired-count 0 \
    --region "${REGION}" > /dev/null
  echo "   Waiting for tasks to stop..."
  aws ecs wait services-stable \
    --cluster "${ECS_CLUSTER}" \
    --services "${ECS_SERVICE}" \
    --region "${REGION}" || true
else
  echo "   ECS service not found or already inactive — skipping."
fi

# ── 2. Force-delete all images from ECR so the repo can be destroyed ─────────
echo ""
echo ">> Deleting all images from ECR repo '${ECR_REPO}'..."
IMAGE_IDS=$(aws ecr list-images \
  --repository-name "${ECR_REPO}" \
  --region "${REGION}" \
  --query "imageIds[*]" \
  --output json 2>/dev/null || echo "[]")
if [ "${IMAGE_IDS}" != "[]" ] && [ -n "${IMAGE_IDS}" ]; then
  aws ecr batch-delete-image \
    --repository-name "${ECR_REPO}" \
    --image-ids "${IMAGE_IDS}" \
    --region "${REGION}" > /dev/null
  echo "   Images deleted."
else
  echo "   No images found — skipping."
fi

# ── 3. Terraform destroy for remaining resources ──────────────────────────────
echo ""
echo ">> Running terraform destroy..."
cd "${TF_DIR}"
terraform destroy -auto-approve

echo ""
echo "Done. Experiment 1 AWS resources destroyed."
echo "(Main platform — VPC, ALB, RDS, DynamoDB — still running.)"
