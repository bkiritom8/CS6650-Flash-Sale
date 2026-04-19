#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVICE_NAME="concert-platform"
REGION="us-east-1"
ECR_REPOS=(
  "concert-inventory-service"
  "concert-booking-service"
  "concert-queue-service"
)
ECS_CLUSTER="${SERVICE_NAME}-cluster"
ECS_SERVICES=(
  "${SERVICE_NAME}-inventory"
  "${SERVICE_NAME}-booking"
  "${SERVICE_NAME}-queue"
)

echo "================================================"
echo "  Concert Ticket Platform — Cleanup"
echo "  This will destroy ALL AWS resources:"
echo "    VPC, ALB, ECS (3 services), RDS, DynamoDB,"
echo "    ECR (3 repos), CloudWatch log groups"
echo "================================================"
echo ""
read -rp "Are you sure? Type 'yes' to confirm: " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# ── 1. Scale all ECS services to 0 so tasks drain before destroy ─────────────
echo ""
echo ">> Scaling ECS services to 0..."
for SVC in "${ECS_SERVICES[@]}"; do
  if aws ecs describe-services \
       --cluster "${ECS_CLUSTER}" \
       --services "${SVC}" \
       --region "${REGION}" \
       --query "services[0].status" --output text 2>/dev/null | grep -q "ACTIVE"; then
    echo "   Scaling down: ${SVC}"
    aws ecs update-service \
      --cluster "${ECS_CLUSTER}" \
      --service "${SVC}" \
      --desired-count 0 \
      --region "${REGION}" > /dev/null
  else
    echo "   ${SVC} not found or already inactive — skipping."
  fi
done

echo "   Waiting for all tasks to stop..."
for SVC in "${ECS_SERVICES[@]}"; do
  aws ecs wait services-stable \
    --cluster "${ECS_CLUSTER}" \
    --services "${SVC}" \
    --region "${REGION}" 2>/dev/null || true
done

# ── 2. Force-delete all images from ECR repos so they can be destroyed ────────
echo ""
echo ">> Deleting all ECR images..."
for REPO in "${ECR_REPOS[@]}"; do
  IMAGE_IDS=$(aws ecr list-images \
    --repository-name "${REPO}" \
    --region "${REGION}" \
    --query "imageIds[*]" \
    --output json 2>/dev/null || echo "[]")
  if [ "${IMAGE_IDS}" != "[]" ] && [ -n "${IMAGE_IDS}" ]; then
    echo "   Deleting images from: ${REPO}"
    aws ecr batch-delete-image \
      --repository-name "${REPO}" \
      --image-ids "${IMAGE_IDS}" \
      --region "${REGION}" > /dev/null
  else
    echo "   No images in ${REPO} — skipping."
  fi
done

# ── 3. Force-terminate any tagged EC2 instances (e.g. experiment MongoDB) ─────
echo ""
echo ">> Terminating any experiment EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${SERVICE_NAME}-*" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text \
  --region "${REGION}" 2>/dev/null || true)
if [ -n "${INSTANCE_IDS}" ]; then
  echo "   Terminating: ${INSTANCE_IDS}"
  aws ec2 terminate-instances \
    --instance-ids ${INSTANCE_IDS} \
    --region "${REGION}" > /dev/null
  echo "   Waiting for termination..."
  aws ec2 wait instance-terminated \
    --instance-ids ${INSTANCE_IDS} \
    --region "${REGION}" || true
  echo "   Instance(s) terminated."
else
  echo "   No tagged EC2 instances found — skipping."
fi

# ── 4. Terraform destroy for remaining resources ──────────────────────────────
echo ""
echo ">> Running terraform destroy..."
cd "${ROOT_DIR}/terraform/main"
terraform destroy -auto-approve

echo ""
echo "Done. All AWS resources destroyed."
echo "(NAT Gateway, RDS, and ECS charges have stopped.)"
