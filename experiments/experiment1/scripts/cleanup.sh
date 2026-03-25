#!/bin/bash
set -euo pipefail

EXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${EXP_DIR}/terraform"

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

cd "${TF_DIR}"
terraform destroy -auto-approve

echo ""
echo "Done. Experiment 1 AWS resources destroyed."
echo "(Main platform — VPC, ALB, RDS, DynamoDB — still running.)"
