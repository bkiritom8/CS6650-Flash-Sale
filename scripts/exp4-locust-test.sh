#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCUST_FILE="${REPO_ROOT}/experiments/experiment4/locustfile.py"
PARSE_SCRIPT="${REPO_ROOT}/experiments/experiment4/parse_stats.py"
MAIN_TF="${REPO_ROOT}/terraform/main"

# ── Tunable parameters ────────────────────────────────────────────────────────
# Run at two concurrency levels to observe bleed threshold
USERS_LOW="${USERS_LOW:-500}"
USERS_HIGH="${USERS_HIGH:-1000}"
SPAWN_RATE="${SPAWN_RATE:-50}"
RUN_TIME="${RUN_TIME:-120s}"
BACKENDS="${BACKENDS:-mysql dynamodb}"

# ── Directories — repo-local, works on all OS ─────────────────────────────────
CSV_DIR="${REPO_ROOT}/.tmp/exp4_locust"
LOG_DIR="${REPO_ROOT}/.tmp/exp4_logs"
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
SUMMARY_CSV="${RESULTS_DIR}/exp4_${TIMESTAMP}.csv"

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Reset DB ──────────────────────────────────────────────────────────────────
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

# ── Run one test (backend + user count) ───────────────────────────────────────
run_test() {
    local backend=$1
    local users=$2
    local csv_suffix="${backend}_${users}users"
    local csv_prefix="${CSV_DIR}/${csv_suffix}"
    local log_file="${LOG_DIR}/${csv_suffix}.log"

    echo ""
    echo "  Running: ${backend} / ${users} users / all 5 events simultaneously"

    locust -f "${LOCUST_FILE}" \
        --host        "${BOOKING_URL}" \
        --headless \
        --users       "${users}" \
        --spawn-rate  "${SPAWN_RATE}" \
        --run-time    "${RUN_TIME}" \
        --db-backend  "${backend}" \
        --csv         "${csv_prefix}" \
        --loglevel    WARNING \
        > "${log_file}" 2>&1 || true

    # Parse per-event stats from CSV
    local stats_file="${csv_prefix}_stats.csv"
    if [ ! -f "${stats_file}" ]; then
        echo "    WARNING: No stats CSV found — Locust may have exited early"
        echo "    Check log: ${log_file}"
        fail "${backend}/${users}users: no stats generated"
        return
    fi

    echo ""
    echo "  Per-event results (${backend}, ${users} users):"
    printf "    %-10s %8s %7s %7s %7s %9s %9s\n" \
        "Event" "Avg(ms)" "p50" "p95" "p99" "Requests" "Failures"
    printf "    %-10s %8s %7s %7s %7s %9s %9s\n" \
        "-----" "-------" "---" "---" "---" "--------" "--------"

    local total_reqs=0
    local total_fails=0
    local any_event_found=0

    while IFS=' ' read -r event_id avg p50 p95 p99 reqs fails; do
        # Strip carriage returns — Python on Windows outputs \r\n
        event_id=$(echo "${event_id}" | tr -d '\r')
        avg=$(echo "${avg}"   | tr -d '\r')
        p50=$(echo "${p50}"   | tr -d '\r')
        p95=$(echo "${p95}"   | tr -d '\r')
        p99=$(echo "${p99}"   | tr -d '\r')
        reqs=$(echo "${reqs}" | tr -d '\r')
        fails=$(echo "${fails}"| tr -d '\r')
        if [ "${event_id}" = "-" ]; then
            continue
        fi
        any_event_found=1
        printf "    %-10s %8s %7s %7s %7s %9s %9s\n" \
            "${event_id}" "${avg}" "${p50}" "${p95}" "${p99}" "${reqs}" "${fails}"

        # Save to summary CSV
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "${backend}" "${users}" "${event_id}" \
            "${avg}" "${p50}" "${p95}" "${p99}" \
            "${reqs}" "${fails}" >> "${SUMMARY_CSV}"

        if [ "${reqs}" != "-" ] && [ "${reqs:-0}" -gt 0 ] 2>/dev/null; then
            total_reqs=$(( total_reqs + ${reqs//[^0-9]/} ))
            total_fails=$(( total_fails + ${fails//[^0-9]/} ))
        fi
    done < <($PY "${PARSE_SCRIPT}" "${stats_file}" 2>/dev/null)

    if [ "${any_event_found}" = "0" ]; then
        fail "${backend}/${users}users: no per-event data found in CSV"
        return
    fi

    echo ""
    echo "    Total: ${total_reqs} requests, ${total_fails} failures"

    if [ "${total_fails:-0}" -eq 0 ] 2>/dev/null; then
        ok "${backend}/${users}users: 0 failures across all events"
    else
        # Failures here mean genuine errors (not 409s which are marked success)
        fail "${backend}/${users}users: ${total_fails} genuine failures"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  Experiment 4 — Multiple Concurrent Flash Sales"
echo "  Booking URL : ${BOOKING_URL}"
echo "  Backends    : ${BACKENDS}"
echo "  Users (low) : ${USERS_LOW}  (USERS_LOW=N to override)"
echo "  Users (high): ${USERS_HIGH}  (USERS_HIGH=N to override)"
echo "  Spawn rate  : ${SPAWN_RATE}/s  (SPAWN_RATE=N to override)"
echo "  Run time    : ${RUN_TIME}  (RUN_TIME=Xs to override)"
echo "=============================================================="
echo ""
echo "  Event distribution (approximate):"
echo "    evt-001 Taylor Swift    ~40% of users  HIGH demand"
echo "    evt-005 Drake           ~25% of users"
echo "    evt-002 Coldplay        ~15% of users"
echo "    evt-003 The Weeknd      ~12% of users"
echo "    evt-004 Billie Eilish    ~8% of users  LOW demand"
echo ""
echo "  NOTE: 409 responses are lock contention events, not failures."
echo "  They are counted per-event and printed at end of each Locust run."
echo "=============================================================="

# ── Health checks ─────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health checks"
for svc in inventory booking queue; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${BOOKING_URL}/${svc}/health")
    if [ "$HTTP" = "200" ]; then ok "${svc}-service /health (HTTP 200)"
    else fail "${svc}-service /health (expected 200, got ${HTTP})"; fi
done

# ── Write CSV header ──────────────────────────────────────────────────────────
printf "backend,users,event_id,avg_ms,p50_ms,p95_ms,p99_ms,requests,failures\n" \
    > "${SUMMARY_CSV}"

# ── Run all combinations ──────────────────────────────────────────────────────
IDX=2
for backend in ${BACKENDS}; do
    echo ""
    echo "=============================================================="
    echo "  Backend: ${backend}"
    echo "=============================================================="

    switch_backend "${backend}"

    # Low concurrency run
    echo ""
    echo "--- [${IDX}] ${backend} / ${USERS_LOW} users"
    reset_db
    run_test "${backend}" "${USERS_LOW}"
    IDX=$(( IDX + 1 ))

    # High concurrency run
    echo ""
    echo "--- [${IDX}] ${backend} / ${USERS_HIGH} users"
    reset_db
    run_test "${backend}" "${USERS_HIGH}"
    IDX=$(( IDX + 1 ))
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  RESULTS SUMMARY — Per-event latency across all runs"
echo "=============================================================="
printf "  %-10s %6s %-10s %8s %7s %7s %7s %9s %9s\n" \
    "Backend" "Users" "Event" "Avg(ms)" "p50" "p95" "p99" "Requests" "Failures"
printf "  %-10s %6s %-10s %8s %7s %7s %7s %9s %9s\n" \
    "-------" "-----" "-----" "-------" "---" "---" "---" "--------" "--------"

tail -n +2 "${SUMMARY_CSV}" | while IFS=',' read -r backend users event_id avg p50 p95 p99 reqs fails; do
    printf "  %-10s %6s %-10s %8s %7s %7s %7s %9s %9s\n" \
        "${backend}" "${users}" "${event_id}" \
        "${avg}" "${p50}" "${p95}" "${p99}" "${reqs}" "${fails}"
done

echo ""
echo "  Tests passed: ${PASS}  |  Tests failed: ${FAIL}"
echo "=============================================================="
echo ""
echo "  Results CSV : ${SUMMARY_CSV}"
echo "  Locust logs : ${LOG_DIR}/"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "  Check logs:"
    echo "  aws logs tail /ecs/concert-platform-booking --follow --region us-east-1"
    exit 1
fi

echo "All experiment 4 tests passed."