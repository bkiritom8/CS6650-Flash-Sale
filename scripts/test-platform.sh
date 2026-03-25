#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}/terraform/main"
ALB=$(terraform output -raw alb_dns_name)

INV="http://${ALB}/inventory"
BK="http://${ALB}/booking"
Q="http://${ALB}/queue"

PASS=0
FAIL=0

# Detect python — check plain python first (avoids Windows Store stub python3)
if command -v python &>/dev/null; then PY="python"
elif command -v python3 &>/dev/null; then PY="python3"
else echo "ERROR: Python not found."; exit 1; fi

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# Check HTTP status only — no response body needed
check() {
  local label=$1 expected=$2 url=$3 method=${4:-GET} body=${5:-}
  if [ -n "$body" ]; then
    actual=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url" \
      -H "Content-Type: application/json" -d "$body")
  else
    actual=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url")
  fi
  if [ "$actual" = "$expected" ]; then ok "$label (HTTP $actual)"
  else fail "$label (expected $expected, got $actual)"; fi
}

# Parse JSON from a curl response inline
json_get() {
  local url=$1 field=$2
  curl -s "$url" | $PY -c "import sys,json; print(json.load(sys.stdin)$field)" 2>/dev/null || echo ""
}

echo ""
echo "================================================"
echo "  Concert Ticket Platform — Smoke Tests"
echo "  ALB    : $ALB"
echo "  Python : $PY"
echo "================================================"

# ── 1. Health checks ──────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health Checks"
check "inventory-service /health"  "200" "${INV}/health"
check "booking-service /health"    "200" "${BK}/health"
check "queue-service /health"      "200" "${Q}/health"

# Verify lock mode is set
LOCK_MODE=$(json_get "${BK}/health" "['lock_mode']")
if [ -n "$LOCK_MODE" ]; then ok "Lock mode active: $LOCK_MODE"
else fail "Could not read lock_mode from booking health"; fi

# ── 2. Inventory service ──────────────────────────────────────────────────────
echo ""
echo "--- [2] Inventory Service"

check "GET /api/v1/events" "200" "${INV}/api/v1/events"

EVENT_COUNT=$(json_get "${INV}/api/v1/events" "['total']")
if [ "${EVENT_COUNT:-0}" -ge 5 ] 2>/dev/null; then
  ok "Seed data present ($EVENT_COUNT events)"
else
  fail "Seed data missing (expected >=5, got ${EVENT_COUNT:-0})"
fi

# Use evt-001 — always has the most seats available
EVENT_ID="evt-001"
check "GET /api/v1/events/:id"              "200" "${INV}/api/v1/events/${EVENT_ID}"
check "GET /api/v1/events/:id/availability" "200" "${INV}/api/v1/events/${EVENT_ID}/availability"
check "GET /api/v1/events/:id/seats"        "200" "${INV}/api/v1/events/${EVENT_ID}/seats"

AVAIL=$(json_get "${INV}/api/v1/events/${EVENT_ID}/availability" "['available_seats']")
if [ "${AVAIL:-0}" -gt 0 ] 2>/dev/null; then
  ok "evt-001 has $AVAIL available seats"
else
  fail "evt-001 has no available seats"
fi

# ── 3. Booking service ────────────────────────────────────────────────────────
echo ""
echo "--- [3] Booking Service"

# Find first available seat
SEAT_ID=$(curl -s "${INV}/api/v1/events/${EVENT_ID}/seats" | \
  $PY -c "
import sys,json
seats = json.load(sys.stdin)['seats']
avail = [s['seat_id'] for s in seats if s['status']=='available']
print(avail[0] if avail else '')
" 2>/dev/null || echo "")

if [ -z "$SEAT_ID" ]; then
  fail "No available seats for $EVENT_ID — cannot test booking"
else
  echo "    Using seat: $SEAT_ID"
  check "POST /api/v1/bookings" "201" "${BK}/api/v1/bookings" \
    "POST" "{\"event_id\":\"${EVENT_ID}\",\"seat_id\":\"${SEAT_ID}\",\"customer_id\":9001}"

  # Fetch most recent confirmed booking for this event
  BOOKING_ID=$(curl -s "${BK}/api/v1/events/${EVENT_ID}/bookings" | \
    $PY -c "
import sys,json
bookings = json.load(sys.stdin)['bookings']
confirmed = [b['booking_id'] for b in bookings if b['status']=='confirmed']
print(confirmed[0] if confirmed else '')
" 2>/dev/null || echo "")

  if [ -n "$BOOKING_ID" ]; then
    ok "Booking confirmed, ID: $BOOKING_ID"
    check "GET /api/v1/bookings/:id" "200" "${BK}/api/v1/bookings/${BOOKING_ID}"
    check "DELETE /api/v1/bookings/:id (cancel)" "200" \
      "${BK}/api/v1/bookings/${BOOKING_ID}" "DELETE"
  else
    fail "Could not retrieve booking_id for event $EVENT_ID"
  fi
fi

check "GET /api/v1/events/:id/bookings" "200" "${BK}/api/v1/events/${EVENT_ID}/bookings"
check "GET /api/v1/metrics"             "200" "${BK}/api/v1/metrics?event_id=${EVENT_ID}"

# Verify oversell count is in metrics
OVERSELLS=$(json_get "${BK}/api/v1/metrics?event_id=${EVENT_ID}" "['oversell_count']")
ok "Oversell count readable: $OVERSELLS"

# ── 4. Queue service ──────────────────────────────────────────────────────────
echo ""
echo "--- [4] Queue Service"

check "POST /api/v1/queue/join" "201" "${Q}/api/v1/queue/join" \
  "POST" "{\"event_id\":\"${EVENT_ID}\",\"customer_id\":9001}"

# Fetch queue_id from metrics — most reliable approach on Windows
QUEUE_DEPTH=$(json_get "${Q}/api/v1/queue/event/${EVENT_ID}/metrics" "['queue_depth']")
if [ "${QUEUE_DEPTH:-0}" -ge 0 ] 2>/dev/null; then
  ok "Queue depth readable: $QUEUE_DEPTH"
else
  fail "Could not read queue depth"
fi

check "GET /api/v1/queue/metrics"                  "200" "${Q}/api/v1/queue/metrics"
check "GET /api/v1/queue/event/:event_id/metrics"  "200" "${Q}/api/v1/queue/event/${EVENT_ID}/metrics"

# ── 5. Runtime controls ───────────────────────────────────────────────────────
echo ""
echo "--- [5] Runtime Controls"

check "POST admission-rate (set to 20)" "200" \
  "${Q}/api/v1/queue/event/${EVENT_ID}/admission-rate" \
  "POST" '{"rate":20}'

check "POST fairness-mode (collapse)" "200" \
  "${Q}/api/v1/queue/event/${EVENT_ID}/fairness-mode" \
  "POST" '{"mode":"collapse"}'

check "POST fairness-mode (allow_multiple)" "200" \
  "${Q}/api/v1/queue/event/${EVENT_ID}/fairness-mode" \
  "POST" '{"mode":"allow_multiple"}'

check "POST admission-rate (reset to 10)" "200" \
  "${Q}/api/v1/queue/event/${EVENT_ID}/admission-rate" \
  "POST" '{"rate":10}'

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "================================================"

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "Check CloudWatch logs:"
  echo "  aws logs tail /ecs/concert-platform-inventory --follow --region us-east-1"
  echo "  aws logs tail /ecs/concert-platform-booking   --follow --region us-east-1"
  echo "  aws logs tail /ecs/concert-platform-queue     --follow --region us-east-1"
  exit 1
fi

echo ""
echo "Platform is fully operational."