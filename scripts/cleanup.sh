#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

cd "${ROOT_DIR}/terraform/main"
terraform destroy -auto-approve

echo ""
echo "Done. All AWS resources destroyed."
echo "(NAT Gateway, RDS, and ECS charges have stopped.)"