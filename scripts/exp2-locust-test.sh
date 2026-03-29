#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCUST_FILE="${REPO_ROOT}/experiments/experiment2/locustfile.py"
PARSE_SCRIPT="${REPO_ROOT}/experiments/experiment2/parse_stats.py"
MAIN_TF="${REPO_ROOT}/terraform/main"

# ── Tunable parameters ────────────────────────────────────────────────────────
USERS="${USERS:-500}"
SPAWN_RATE="${SPAWN_RATE:-200}"
RUN_TIME="${RUN_TIME:-120s}"
EVENT_ID="${EVENT_ID:-evt-001}"
BACKENDS="${BACKENDS:-mysql dynamodb}"
QUEUE_POLL_INTERVAL="${QUEUE_POLL_INTERVAL:-5}"

# ── Directories — repo-local, works on all OS ─────────────────────────────────
CSV_DIR="${REPO_ROOT}/.tmp/exp2_locust"
LOG_DIR="${REPO_ROOT}/.tmp/exp2_logs"
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${CSV_DIR}" "${LOG_DIR}" "${RESULTS_DIR}"

# ── Python detection ──────────────────────────────────────────────────────────
if command -v python &>/dev/null; then PY="python"
elif command -v python3 &>/dev/null; then PY="python3"
else echo "ERROR: Python not found."; exit 1; fi

# ── Locust detection ──────────────────────────────────────────────────────────
if ! command -v locust &>/dev/null; then
    echo "ERROR: locust not found. Run: pip install locust"
    exit 1
fi

# ── Get ALB URL from Terraform — always fresh ─────────────────────────────────
cd "${MAIN_TF}"
if ! terraform output alb_dns_name > /dev/null 2>&1; then
    echo ""
    echo "ERROR: Platform is not deployed. Run: ./scripts/deploy.sh"
    exit 1
fi
ALB=$(terraform output -raw alb_dns_name)
BOOKING_URL="http://${ALB}"
cd "${REPO_ROOT}"

PASS=0
FAIL=0
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SUMMARY_CSV="${RESULTS_DIR}/exp2_${TIMESTAMP}.csv"

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Reset DB between tests ────────────────────────────────────────────────────
reset_db() {
    echo "    Resetting booking and inventory data..."
    curl -sf -X POST "${BOOKING_URL}/booking/api/v1/reset" > /dev/null 2>&1 || true
    sleep 3
}

# ── Switch backend via Terraform ──────────────────────────────────────────────
switch_backend() {
    local backend=$1
    echo "    Switching backend to: ${backend}..."
    cd "${MAIN_TF}"
    terraform apply -auto-approve -var="db_backend=${backend}" > /dev/null 2>&1
    cd "${REPO_ROOT}"

    echo -n "    Waiting for services to stabilise "
    local attempts=0
    until curl -sf "${BOOKING_URL}/booking/health" > /dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 20 ]; then
            echo ""
            echo "ERROR: Health check timed out after switching to ${backend}"
            exit 1
        fi
        echo -n "."
        sleep 10
    done
    echo " ready"
}

# ── Poll queue metrics in background, save snapshots ─────────────────────────
poll_queue_metrics() {
    local out_file=$1
    local sentinel=$2
    local snap=0
    > "${out_file}"
    while [ -f "${sentinel}" ]; do
        local result
        result=$(curl -sf "${BOOKING_URL}/queue/api/v1/queue/event/${EVENT_ID}/metrics" 2>/dev/null || echo "{}")
        echo "{\"snapshot\":${snap},\"data\":${result}}" >> "${out_file}"
        snap=$((snap + 1))
        sleep "${QUEUE_POLL_INTERVAL}"
    done
}

# ── Parse Locust CSV for summary stats ────────────────────────────────────────
parse_locust_stats() {
    local csv_prefix=$1
    local stats_file="${csv_prefix}_stats.csv"
    if [ ! -f "${stats_file}" ]; then
        echo "- - - - - -"
        return
    fi
    $PY "${PARSE_SCRIPT}" "${stats_file}" 2>/dev/null || echo "- - - - - -"
}

# ── Run one scenario (direct or queued) ──────────────────────────────────────
# Args: backend scenario user_class csv_suffix
run_scenario() {
    local backend=$1
    local scenario=$2
    local user_class=$3
    local csv_suffix=$4
    local csv_prefix="${CSV_DIR}/${backend}_${csv_suffix}"
    local log_file="${LOG_DIR}/${backend}_${csv_suffix}.log"
    local queue_file="${CSV_DIR}/${backend}_${csv_suffix}_queue_metrics.jsonl"
    local sentinel="${CSV_DIR}/${backend}_${csv_suffix}.sentinel"

    echo ""
    echo "  Running: ${backend} / ${scenario}"

    # Start queue metric polling in background (only for queued scenario)
    if [ "${scenario}" = "queued" ]; then
        touch "${sentinel}"
        poll_queue_metrics "${queue_file}" "${sentinel}" &
        POLL_PID=$!
    fi

    # Run Locust
    locust -f "${LOCUST_FILE}" "${user_class}" \
        --host        "${BOOKING_URL}" \
        --headless \
        --users       "${USERS}" \
        --spawn-rate  "${SPAWN_RATE}" \
        --run-time    "${RUN_TIME}" \
        --csv         "${csv_prefix}" \
        --loglevel    WARNING \
        > "${log_file}" 2>&1 || true

    # Stop queue metric polling
    if [ "${scenario}" = "queued" ]; then
        rm -f "${sentinel}"
        wait $POLL_PID 2>/dev/null || true
        echo "    Queue metrics saved to: ${queue_file}"
    fi

    # Parse stats
    local stats
    stats=$(parse_locust_stats "${csv_prefix}")
    local avg p50 p95 p99 reqs fails
    avg=$(echo "${stats}"  | cut -d' ' -f1)
    p50=$(echo "${stats}"  | cut -d' ' -f2)
    p95=$(echo "${stats}"  | cut -d' ' -f3)
    p99=$(echo "${stats}"  | cut -d' ' -f4)
    reqs=$(echo "${stats}" | cut -d' ' -f5)
    fails=$(echo "${stats}"| cut -d' ' -f6)

    local success_rate="-"
    if [ "${reqs}" != "-" ] && [ "${reqs:-0}" -gt 0 ] 2>/dev/null; then
        local successes=$(( reqs - ${fails:-0} ))
        success_rate=$($PY -c "print(f'{${successes}/${reqs}*100:.1f}%')" 2>/dev/null || echo "-")
    fi

    echo "    Requests : ${reqs}  Failures: ${fails}  Success: ${success_rate}"
    echo "    Latency  : avg=${avg}ms  p50=${p50}ms  p95=${p95}ms  p99=${p99}ms"

    # Save to summary CSV
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "${backend}" "${scenario}" "${reqs}" "${fails}" "${success_rate}" \
        "${avg}" "${p50}" "${p95}" "${p99}" \
        "${queue_file}" >> "${SUMMARY_CSV}"

    # Basic correctness check
    if [ "${fails:-0}" = "0" ] 2>/dev/null; then
        ok "${backend}/${scenario}: 0 failures"
    else
        fail "${backend}/${scenario}: ${fails} failures out of ${reqs} requests"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  Experiment 2 — Virtual Queue as Demand Buffer"
echo "  Booking URL  : ${BOOKING_URL}"
echo "  Backends     : ${BACKENDS}"
echo "  Users        : ${USERS}  (USERS=N to override)"
echo "  Spawn rate   : ${SPAWN_RATE}/s  (SPAWN_RATE=N to override)"
echo "  Run time     : ${RUN_TIME}  (RUN_TIME=Xs to override)"
echo "  Event        : ${EVENT_ID}"
echo "  Queue poll   : every ${QUEUE_POLL_INTERVAL}s during queued tests"
echo "=============================================================="
echo ""
echo "  NOTE: 409 responses in this experiment are MySQL deadlocks"
echo "  caused by multiple users booking different seats at the same"
echo "  time under pessimistic locking. This is NOT a connectivity"
echo "  issue — the server is healthy and responding correctly."
echo "  The queued scenario should show significantly fewer 409s"
echo "  since requests arrive at a controlled rate."
echo "=============================================================="
echo ""
echo "--- [1] Health checks"
for svc in inventory booking queue; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${BOOKING_URL}/${svc}/health")
    if [ "$HTTP" = "200" ]; then ok "${svc}-service /health (HTTP 200)"
    else fail "${svc}-service /health (expected 200, got ${HTTP})"; fi
done

# ── Write CSV header ──────────────────────────────────────────────────────────
printf "backend,scenario,requests,failures,success_rate,avg_ms,p50_ms,p95_ms,p99_ms,queue_metrics_file\n" \
    > "${SUMMARY_CSV}"

# ── Run all backend x scenario combinations ───────────────────────────────────
IDX=2
for backend in ${BACKENDS}; do
    echo ""
    echo "=============================================================="
    echo "  Backend: ${backend}"
    echo "=============================================================="

    switch_backend "${backend}"

    # Test 1: Direct booking
    echo ""
    echo "--- [${IDX}] ${backend} / direct booking"
    reset_db
    run_scenario "${backend}" "direct" "DirectBookingUser" "direct"
    IDX=$(( IDX + 1 ))

    # Test 2: Queued booking
    echo ""
    echo "--- [${IDX}] ${backend} / queued booking"
    reset_db
    run_scenario "${backend}" "queued" "QueuedBookingUser" "queued"
    IDX=$(( IDX + 1 ))
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  RESULTS SUMMARY"
echo "=============================================================="
printf "  %-10s %-8s %8s %8s %10s %8s %7s %7s %7s\n" \
    "Backend" "Scenario" "Requests" "Failures" "Success%" "Avg(ms)" "p50" "p95" "p99"
printf "  %-10s %-8s %8s %8s %10s %8s %7s %7s %7s\n" \
    "-------" "--------" "--------" "--------" "---------" "-------" "---" "---" "---"

tail -n +2 "${SUMMARY_CSV}" | while IFS=',' read -r backend scenario reqs fails sr avg p50 p95 p99 qfile; do
    printf "  %-10s %-8s %8s %8s %10s %8s %7s %7s %7s\n" \
        "${backend}" "${scenario}" "${reqs}" "${fails}" "${sr}" "${avg}" "${p50}" "${p95}" "${p99}"
done

echo ""
echo "  Tests passed: ${PASS}  |  Tests failed: ${FAIL}"
echo "=============================================================="
echo ""
echo "  Results CSV    : ${SUMMARY_CSV}"
echo "  Locust logs    : ${LOG_DIR}/"
echo "  Queue metrics  : ${CSV_DIR}/*_queue_metrics.jsonl"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "  Check logs for failures:"
    echo "  aws logs tail /ecs/concert-platform-booking --follow --region us-east-1"
    exit 1
fi

echo "All experiment 2 tests passed."