#!/bin/bash
set -euo pipefail

EXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${EXP_DIR}/terraform"

SERVICE_NAME="concert-platform"
REGION="us-east-1"
ECR_REPO="${SERVICE_NAME}-experiment1"
ECS_CLUSTER="${SERVICE_NAME}-experiment1-cluster"
ECS_SERVICE="${SERVICE_NAME}-experiment1"
MONGODB_TAG_KEY="Name"
MONGODB_TAG_VALUE="${SERVICE_NAME}-exp1-mongodb"

echo "================================================"
echo "  Experiment 1 — Cleanup"
echo "  This will destroy experiment1 AWS resources:"
echo "    ECR repo, ECS cluster/service/task,"
echo "    ALB target group + listener rule,"
echo "    MongoDB EC2 instance + security group,"
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

# ── 3. Force-terminate the MongoDB EC2 instance ───────────────────────────────
echo ""
echo ">> Terminating MongoDB EC2 instance (tag ${MONGODB_TAG_KEY}=${MONGODB_TAG_VALUE})..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGODB_TAG_KEY},Values=${MONGODB_TAG_VALUE}" \
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
  echo "   No running MongoDB instance found — skipping."
fi

# ── 4. Terraform destroy for remaining resources ──────────────────────────────
echo ""
echo ">> Running terraform destroy..."
cd "${TF_DIR}"
terraform destroy -auto-approve

echo ""
echo "Done. Experiment 1 AWS resources destroyed."
echo "(Main platform — VPC, ALB, RDS, DynamoDB — still running.)"
