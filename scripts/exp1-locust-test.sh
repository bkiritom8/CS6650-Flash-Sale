#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCUST_FILE="${REPO_ROOT}/experiments/experiment1/experiment1.py"
PARSE_SCRIPT="${REPO_ROOT}/experiments/experiment1/parse_stats.py"
CHART_SCRIPT="${REPO_ROOT}/experiments/experiment1/generate_chart.py"
MAIN_TF="${REPO_ROOT}/terraform/main"

# ── Tunable parameters ────────────────────────────────────────────────────────
CONCURRENCY="${CONCURRENCY:-1000}"
SPAWN_RATE="${SPAWN_RATE:-1000}"
RUN_TIME="${RUN_TIME:-60s}"
MAX_RETRIES="${MAX_RETRIES:-3}"
BACKENDS="${BACKENDS:-mysql dynamodb}"

PASS=0
FAIL=0

# Use repo-local tmp dir — /tmp is unreliable on Windows Git Bash
CSV_DIR="${REPO_ROOT}/.tmp/exp1_locust"
LOG_DIR="${REPO_ROOT}/.tmp/exp1_logs"
mkdir -p "${CSV_DIR}" "${LOG_DIR}"

# ── Python detection ──────────────────────────────────────────────────────────
if command -v python &>/dev/null; then PY="python"
elif command -v python3 &>/dev/null; then PY="python3"
else echo "ERROR: Python not found."; exit 1; fi

# ── Locust detection ──────────────────────────────────────────────────────────
if ! command -v locust &>/dev/null; then
    echo "ERROR: locust not found. Run: pip install -r experiments/experiment1/requirements.txt"
    exit 1
fi

# ── Get ALB URL from Terraform — always fresh, no hardcoding ─────────────────
cd "${MAIN_TF}"
if ! terraform output alb_dns_name > /dev/null 2>&1; then
    echo ""
    echo "ERROR: Platform is not deployed. Run: ./scripts/deploy.sh"
    exit 1
fi
ALB=$(terraform output -raw alb_dns_name)
BOOKING_URL="http://${ALB}"
cd "${REPO_ROOT}"

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Results stored as flat variables with index suffix ────────────────────────
# Avoids associative arrays and process substitution — both unreliable on Windows
RESULT_COUNT=0

store_result() {
    local idx=$1
    eval "RES_BACKEND_${idx}=$2"
    eval "RES_MODE_${idx}=$3"
    eval "RES_BOOKINGS_${idx}=$4"
    eval "RES_OVERSELLS_${idx}=$5"
    eval "RES_LEGIT_${idx}=$6"
    eval "RES_FAILED_${idx}=$7"
    eval "RES_AVG_${idx}=$8"
    eval "RES_P50_${idx}=$9"
    eval "RES_P95_${idx}=${10}"
    eval "RES_P99_${idx}=${11}"
    eval "RES_STATUS_${idx}=${12}"
}

get_result() {
    local idx=$1 field=$2
    eval "echo \${RES_${field}_${idx}}"
}

# ── run_mode <backend> <lock_mode> ────────────────────────────────────────────
run_mode() {
    local backend=$1 mode=$2
    local csv_prefix="${CSV_DIR}/${backend}_${mode}"
    local log_file="${LOG_DIR}/${backend}_${mode}.log"

    local seat_id="seat-last"
    local event_id
    event_id="exp1-$($PY -c 'import uuid; print(uuid.uuid4().hex[:8])')"

    printf "  %-10s %-14s  event=%-18s " "${backend}" "${mode}" "${event_id}"

    # 1. Run Locust — errors go to log file, not /dev/null, so they are visible if needed
    locust -f "${LOCUST_FILE}" \
        --host        "${BOOKING_URL}" \
        --headless \
        --users       "${CONCURRENCY}" \
        --spawn-rate  "${SPAWN_RATE}" \
        --run-time    "${RUN_TIME}" \
        --lock-mode   "${mode}" \
        --db-backend  "${backend}" \
        --max-retries "${MAX_RETRIES}" \
        --event-id    "${event_id}" \
        --seat-id     "${seat_id}" \
        --csv         "${csv_prefix}" \
        --loglevel    WARNING \
        > "${log_file}" 2>&1 || true

    # 2. Fetch ground-truth results from booking service
    local bookings oversells
    bookings=$(curl -sf \
        "${BOOKING_URL}/booking/api/v1/events/${event_id}/bookings?db_backend=${backend}" \
        | $PY -c "import sys,json; print(len(json.load(sys.stdin)['bookings']))" 2>/dev/null || echo 0)
    oversells=$(curl -sf \
        "${BOOKING_URL}/booking/api/v1/metrics?event_id=${event_id}&db_backend=${backend}" \
        | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count',0))" 2>/dev/null || echo 0)

    # 3. Parse latency from CSV using external helper — no heredoc needed
    local lat_avg="-" lat_p50="-" lat_p95="-" lat_p99="-"
    if [ -f "${csv_prefix}_stats.csv" ]; then
        local lat_out
        lat_out=$($PY "${PARSE_SCRIPT}" "${csv_prefix}_stats.csv" 2>/dev/null || echo "- - - -")
        lat_avg=$(echo "${lat_out}" | cut -d' ' -f1)
        lat_p50=$(echo "${lat_out}" | cut -d' ' -f2)
        lat_p95=$(echo "${lat_out}" | cut -d' ' -f3)
        lat_p99=$(echo "${lat_out}" | cut -d' ' -f4)
    fi

    # 4. Cleanup test data
    curl -sf -X DELETE \
        "${BOOKING_URL}/booking/api/v1/internal/events/${event_id}/data?db_backend=${backend}" \
        > /dev/null 2>&1 || true

    # 5. Correctness check
    local status
    case "${mode}" in
        none)
            if [ "${oversells:-0}" -gt 0 ] 2>/dev/null; then
                status="PASS"
                ok "${backend}/${mode}: bookings=${bookings} oversells=${oversells} avg=${lat_avg}ms"
            else
                status="FAIL-expected-oversells"
                fail "${backend}/${mode}: expected oversells, got 0 (bookings=${bookings})"
                echo "    Locust log: ${log_file}"
            fi
            ;;
        optimistic|pessimistic)
            if [ "${oversells:-1}" -eq 0 ] 2>/dev/null; then
                status="PASS"
                ok "${backend}/${mode}: bookings=${bookings} oversells=${oversells} avg=${lat_avg}ms"
            else
                status="FAIL-oversells=${oversells}"
                fail "${backend}/${mode}: expected 0 oversells, got ${oversells}"
                echo "    Locust log: ${log_file}"
            fi
            ;;
        *) status="UNKNOWN" ;;
    esac

    local failed=$(( CONCURRENCY - bookings ))
    local legitimate=$(( bookings - oversells ))

    store_result "${RESULT_COUNT}" \
        "${backend}" "${mode}" \
        "${bookings}" "${oversells}" "${legitimate}" "${failed}" \
        "${lat_avg}" "${lat_p50}" "${lat_p95}" "${lat_p99}" \
        "${status}"
    RESULT_COUNT=$(( RESULT_COUNT + 1 ))
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  Experiment 1 — Locking Strategy Benchmark"
echo "  Booking URL : ${BOOKING_URL}"
echo "  Backends    : ${BACKENDS}"
echo "  Concurrency : ${CONCURRENCY} users  (CONCURRENCY=N to override)"
echo "  Spawn rate  : ${SPAWN_RATE}/s        (SPAWN_RATE=N to override)"
echo "  Run time    : ${RUN_TIME}             (RUN_TIME=Xs to override)"
echo "  Strategy    : waiting-room (all users spawn, then rush together)"
echo "=============================================================="

# ── [1] Health check ──────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health check"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${BOOKING_URL}/booking/health")
if [ "$HTTP" = "200" ]; then ok "GET /booking/health (HTTP 200)"
else fail "GET /booking/health (expected 200, got ${HTTP})"; fi

# ── [2-N] Run all backend x mode combinations ─────────────────────────────────
IDX=2
for backend in ${BACKENDS}; do
    for mode in none optimistic pessimistic; do
        echo ""
        echo "--- [${IDX}] ${backend} / ${mode}"
        run_mode "${backend}" "${mode}"
        IDX=$(( IDX + 1 ))
    done
done

# ── Results table — counter loop, no array index iteration ────────────────────
echo ""
echo "=============================================================="
echo "  RESULTS SUMMARY  (${CONCURRENCY} users · waiting-room spawn)"
echo "=============================================================="
printf "  %-10s %-14s %9s %10s %8s %7s %8s %7s %7s %7s  %s\n" \
    "Backend" "Lock Mode" "Bookings" "Oversells" "Legit" "Failed" "Avg(ms)" "p50" "p95" "p99" "Status"
printf "  %-10s %-14s %9s %10s %8s %7s %8s %7s %7s %7s  %s\n" \
    "--------" "----------" "--------" "---------" "-----" "------" "-------" "---" "---" "---" "------"

i=0
while [ $i -lt $RESULT_COUNT ]; do
    printf "  %-10s %-14s %9s %10s %8s %7s %8s %7s %7s %7s  %s\n" \
        "$(get_result $i BACKEND)" "$(get_result $i MODE)" \
        "$(get_result $i BOOKINGS)" "$(get_result $i OVERSELLS)" \
        "$(get_result $i LEGIT)" "$(get_result $i FAILED)" \
        "$(get_result $i AVG)" "$(get_result $i P50)" \
        "$(get_result $i P95)" "$(get_result $i P99)" \
        "$(get_result $i STATUS)"
    i=$(( i + 1 ))
done

echo ""
echo "  Tests passed: ${PASS}  |  Tests failed: ${FAIL}"
echo "=============================================================="

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "  Check booking-service logs:"
    echo "  aws logs tail /ecs/concert-platform-booking --follow --region us-east-1"
    echo ""
fi

# ── Save results to CSV ───────────────────────────────────────────────────────
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_CSV="${RESULTS_DIR}/exp1_${TIMESTAMP}.csv"

printf "backend,lock_mode,concurrency,bookings,oversells,legitimate,failed,avg_ms,p50_ms,p95_ms,p99_ms,status\n" > "${OUT_CSV}"
i=0
while [ $i -lt $RESULT_COUNT ]; do
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$(get_result $i BACKEND)" "$(get_result $i MODE)" "${CONCURRENCY}" \
        "$(get_result $i BOOKINGS)" "$(get_result $i OVERSELLS)" \
        "$(get_result $i LEGIT)" "$(get_result $i FAILED)" \
        "$(get_result $i AVG)" "$(get_result $i P50)" \
        "$(get_result $i P95)" "$(get_result $i P99)" \
        "$(get_result $i STATUS)" >> "${OUT_CSV}"
    i=$(( i + 1 ))
done

echo ""
echo "  Results saved to: ${OUT_CSV}"

# ── Generate PNG chart via external script ────────────────────────────────────
OUT_PNG="${OUT_CSV%.csv}.png"
$PY "${CHART_SCRIPT}" "${OUT_CSV}" "${OUT_PNG}" "${CONCURRENCY}" \
    && echo "  Chart saved to:   ${OUT_PNG}" \
    || echo "  (chart generation skipped — pip install matplotlib numpy to enable)"

echo ""
if [ $FAIL -gt 0 ]; then exit 1; fi
echo "All experiment 1 tests passed."