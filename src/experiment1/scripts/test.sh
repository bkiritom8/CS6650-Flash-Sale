#!/bin/bash
set -euo pipefail

EXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${EXP_DIR}/terraform"

cd "${TF_DIR}"
EXP1_URL=$(terraform output -raw experiment1_url)

PASS=0
FAIL=0

# Detect python
if command -v python &>/dev/null; then PY="python"
elif command -v python3 &>/dev/null; then PY="python3"
else echo "ERROR: Python not found."; exit 1; fi

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

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

# Concurrency for smoke runs — small enough to be fast, big enough to see races
CONCURRENCY="${CONCURRENCY:-50}"

echo ""
echo "================================================"
echo "  Experiment 1 — Tests"
echo "  URL         : $EXP1_URL"
echo "  Concurrency : $CONCURRENCY (override with CONCURRENCY=N)"
echo "================================================"

# ── Health ────────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health"
check "GET /health" "200" "${EXP1_URL}/health"

# ── MySQL runs ────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] MySQL backend"

for mode in none optimistic pessimistic; do
  RESULT=$(curl -s -X POST "${EXP1_URL}/api/v1/run" \
    -H "Content-Type: application/json" \
    -d "{\"lock_mode\":\"${mode}\",\"db_backend\":\"mysql\",\"concurrency\":${CONCURRENCY}}")

  RUN_ID=$( echo "$RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('run_id',''))" 2>/dev/null || echo "")
  OVERSELLS=$(echo "$RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count','?'))" 2>/dev/null || echo "?")
  SUCCESS=$(echo "$RESULT"  | $PY -c "import sys,json; print(json.load(sys.stdin).get('successful_bookings','?'))" 2>/dev/null || echo "?")
  FAILED=$( echo "$RESULT"  | $PY -c "import sys,json; print(json.load(sys.stdin).get('failed_bookings','?'))" 2>/dev/null || echo "?")
  P99=$(    echo "$RESULT"  | $PY -c "import sys,json; print(json.load(sys.stdin).get('latency_ms',{}).get('p99_ms','?'))" 2>/dev/null || echo "?")

  if [ -n "$RUN_ID" ]; then
    ok "MySQL / ${mode}: success=${SUCCESS} failed=${FAILED} oversells=${OVERSELLS} p99=${P99}ms"
  else
    fail "MySQL / ${mode}: run failed — response: $RESULT"
  fi
done

# Correctness assertions for MySQL
echo ""
echo "--- [2b] MySQL correctness assertions"

# no-lock: must have oversells > 0 when concurrency > 1
NONE_RESULT=$(curl -s -X POST "${EXP1_URL}/api/v1/run" \
  -H "Content-Type: application/json" \
  -d "{\"lock_mode\":\"none\",\"db_backend\":\"mysql\",\"concurrency\":${CONCURRENCY}}")
NONE_OVERSELLS=$(echo "$NONE_RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count',0))" 2>/dev/null || echo "0")
if [ "${NONE_OVERSELLS:-0}" -gt 0 ] 2>/dev/null; then
  ok "no-lock produces oversells as expected (oversell_count=${NONE_OVERSELLS})"
else
  fail "no-lock should produce oversells but got ${NONE_OVERSELLS} — check race window"
fi

# optimistic: must have 0 oversells
OPT_RESULT=$(curl -s -X POST "${EXP1_URL}/api/v1/run" \
  -H "Content-Type: application/json" \
  -d "{\"lock_mode\":\"optimistic\",\"db_backend\":\"mysql\",\"concurrency\":${CONCURRENCY}}")
OPT_OVERSELLS=$(echo "$OPT_RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count',1))" 2>/dev/null || echo "1")
if [ "${OPT_OVERSELLS:-1}" -eq 0 ] 2>/dev/null; then
  ok "optimistic produces 0 oversells"
else
  fail "optimistic should produce 0 oversells but got ${OPT_OVERSELLS}"
fi

# pessimistic: must have 0 oversells
PESS_RESULT=$(curl -s -X POST "${EXP1_URL}/api/v1/run" \
  -H "Content-Type: application/json" \
  -d "{\"lock_mode\":\"pessimistic\",\"db_backend\":\"mysql\",\"concurrency\":${CONCURRENCY}}")
PESS_OVERSELLS=$(echo "$PESS_RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count',1))" 2>/dev/null || echo "1")
if [ "${PESS_OVERSELLS:-1}" -eq 0 ] 2>/dev/null; then
  ok "pessimistic produces 0 oversells"
else
  fail "pessimistic should produce 0 oversells but got ${PESS_OVERSELLS}"
fi

# ── DynamoDB runs ─────────────────────────────────────────────────────────────
echo ""
echo "--- [3] DynamoDB backend"

for mode in none optimistic pessimistic; do
  RESULT=$(curl -s -X POST "${EXP1_URL}/api/v1/run" \
    -H "Content-Type: application/json" \
    -d "{\"lock_mode\":\"${mode}\",\"db_backend\":\"dynamodb\",\"concurrency\":${CONCURRENCY}}")

  RUN_ID=$( echo "$RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('run_id',''))" 2>/dev/null || echo "")
  OVERSELLS=$(echo "$RESULT" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count','?'))" 2>/dev/null || echo "?")
  SUCCESS=$(echo "$RESULT"  | $PY -c "import sys,json; print(json.load(sys.stdin).get('successful_bookings','?'))" 2>/dev/null || echo "?")
  FAILED=$( echo "$RESULT"  | $PY -c "import sys,json; print(json.load(sys.stdin).get('failed_bookings','?'))" 2>/dev/null || echo "?")
  P99=$(    echo "$RESULT"  | $PY -c "import sys,json; print(json.load(sys.stdin).get('latency_ms',{}).get('p99_ms','?'))" 2>/dev/null || echo "?")

  if [ -n "$RUN_ID" ]; then
    ok "DynamoDB / ${mode}: success=${SUCCESS} failed=${FAILED} oversells=${OVERSELLS} p99=${P99}ms"
  else
    fail "DynamoDB / ${mode}: run failed — response: $RESULT"
  fi
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
