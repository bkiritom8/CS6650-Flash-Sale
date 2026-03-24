#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}/terraform/main"
ALB=$(terraform output -raw alb_dns_name)

echo ""
echo "=== Concert Ticket Platform — Smoke Tests ==="
echo "ALB: $ALB"
echo ""

echo "--- Health Checks"
curl -s "http://${ALB}/inventory/health" && echo ""
curl -s "http://${ALB}/booking/health" && echo ""
curl -s "http://${ALB}/queue/health" && echo ""

echo ""
echo "--- Events"
curl -s "http://${ALB}/inventory/api/v1/events"
echo ""

echo ""
echo "--- Seats for evt-001"
curl -s "http://${ALB}/inventory/api/v1/events/evt-001/seats" | head -c 500
echo ""

echo ""
echo "--- Create Booking"
curl -s -X POST "http://${ALB}/booking/api/v1/bookings" \
  -H "Content-Type: application/json" \
  -d '{"event_id":"evt-001","seat_id":"evt-001-seat-0010","customer_id":9999}'
echo ""

echo ""
echo "--- Join Queue"
curl -s -X POST "http://${ALB}/queue/api/v1/queue/join" \
  -H "Content-Type: application/json" \
  -d '{"event_id":"evt-001","customer_id":9999}'
echo ""

echo ""
echo "--- Queue Metrics"
curl -s "http://${ALB}/queue/api/v1/queue/metrics"
echo ""

echo ""
echo "=== Done ==="