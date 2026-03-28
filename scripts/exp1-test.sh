#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXP_DIR="${ROOT_DIR}/experiments/experiment1"
TF_DIR="${EXP_DIR}/terraform"

cd "${TF_DIR}"
EXP1_URL=$(terraform output -raw experiment1_url)

CONCURRENCY="${CONCURRENCY:-100}"
RUN_TIME="${RUN_TIME:-20s}"
PASS=0
FAIL=0

# ── Prerequisites ──────────────────────────────────────────────────────────────
if command -v python3 &>/dev/null; then PY="python3"
elif command -v python &>/dev/null; then PY="python"
else echo "ERROR: Python not found."; exit 1; fi

if ! command -v locust &>/dev/null; then
    echo "ERROR: locust not found.  Run: pip install locust"
    exit 1
fi

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ── run_test <label> <lock_mode> <db_backend> ─────────────────────────────────
# Sets LAST_BOOKINGS and LAST_OVERSELLS on return.
LAST_BOOKINGS=0
LAST_OVERSELLS=0

run_test() {
    local label=$1 mode=$2 backend=$3
    local event_id seat_id result

    seat_id="seat-last"
    event_id="exp1-$($PY -c 'import uuid; print(uuid.uuid4().hex[:8])')"

    # 1. Init seat
    if ! curl -sf -X POST "${EXP1_URL}/api/v1/seat/init" \
        -H "Content-Type: application/json" \
        -d "{\"event_id\":\"${event_id}\",\"seat_id\":\"${seat_id}\",\"db_backend\":\"${backend}\"}" \
        > /dev/null; then
        fail "${label}: seat init failed"
        LAST_BOOKINGS=0; LAST_OVERSELLS=0; return
    fi

    # 2. Run Locust — all users spawn simultaneously, each books once
    locust -f "${ROOT_DIR}/locust/experiment1/experiment1.py" \
        --host "${EXP1_URL}" \
        --headless \
        --users "${CONCURRENCY}" \
        --spawn-rate "${CONCURRENCY}" \
        --run-time "${RUN_TIME}" \
        --lock-mode "${mode}" \
        --db-backend "${backend}" \
        --event-id "${event_id}" \
        --seat-id "${seat_id}" \
        --loglevel WARNING \
        2>/dev/null || true


    # 3. Fetch ground-truth results from the server
    result=$(curl -sf \
        "${EXP1_URL}/api/v1/seat/results?event_id=${event_id}&seat_id=${seat_id}&db_backend=${backend}" \
        || echo "{}")
    LAST_BOOKINGS=$(echo  "$result" | $PY -c "import sys,json; print(json.load(sys.stdin).get('booking_count',  0))" 2>/dev/null || echo 0)
    LAST_OVERSELLS=$(echo "$result" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count', 0))" 2>/dev/null || echo 0)

    # 4. Cleanup
    curl -sf -X DELETE \
        "${EXP1_URL}/api/v1/seat?event_id=${event_id}&seat_id=${seat_id}&db_backend=${backend}" \
        > /dev/null || true

    ok "${label}: bookings=${LAST_BOOKINGS} oversells=${LAST_OVERSELLS}"
}

echo ""
echo "================================================"
echo "  Experiment 1 — Locust Tests"
echo "  URL         : $EXP1_URL"
echo "  Concurrency : $CONCURRENCY (override with CONCURRENCY=N)"
echo "  Run time    : $RUN_TIME    (override with RUN_TIME=Xs)"
echo "================================================"

# ── [1] Health ────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${EXP1_URL}/health")
if [ "$HTTP" = "200" ]; then ok "GET /health (HTTP 200)"
else fail "GET /health (expected 200, got $HTTP)"; fi

# ── [2] MySQL backend ─────────────────────────────────────────────────────────
echo ""
echo "--- [2] MySQL backend"
for mode in none optimistic pessimistic; do
    run_test "MySQL / ${mode}" "${mode}" "mysql"
done

# ── [2b] MySQL correctness assertions ─────────────────────────────────────────
echo ""
echo "--- [2b] MySQL correctness assertions"

run_test "MySQL / none (assert)" "none" "mysql"
NONE_OVERSELLS=$LAST_OVERSELLS
if [ "${NONE_OVERSELLS:-0}" -gt 0 ] 2>/dev/null; then
    ok "no-lock produces oversells as expected (oversell_count=${NONE_OVERSELLS})"
else
    fail "no-lock should produce oversells but got ${NONE_OVERSELLS} — check race window"
fi

run_test "MySQL / optimistic (assert)" "optimistic" "mysql"
if [ "${LAST_OVERSELLS:-1}" -eq 0 ] 2>/dev/null; then ok "optimistic produces 0 oversells"
else fail "optimistic should produce 0 oversells but got ${LAST_OVERSELLS}"; fi

run_test "MySQL / pessimistic (assert)" "pessimistic" "mysql"
if [ "${LAST_OVERSELLS:-1}" -eq 0 ] 2>/dev/null; then ok "pessimistic produces 0 oversells"
else fail "pessimistic should produce 0 oversells but got ${LAST_OVERSELLS}"; fi

# ── [3] DynamoDB backend ──────────────────────────────────────────────────────
echo ""
echo "--- [3] DynamoDB backend"
for mode in none optimistic pessimistic; do
    run_test "DynamoDB / ${mode}" "${mode}" "dynamodb"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "================================================"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Check logs:"
    echo "  aws logs tail /ecs/concert-platform-experiment1 --follow --region us-east-1"
    exit 1
fi

echo ""
echo "All experiment 1 tests passed."
