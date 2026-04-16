#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCUST_FILE="${REPO_ROOT}/experiments/experiment5/locustfile.py"
PARSE_SCRIPT="${REPO_ROOT}/experiments/experiment5/parse_stats.py"
CHART_SCRIPT="${REPO_ROOT}/experiments/experiment5/generate_chart.py"
MAIN_TF="${REPO_ROOT}/terraform/main"

# ── Tunable parameters ────────────────────────────────────────────────────────
USERS="${USERS:-400}"
SPAWN_RATE="${SPAWN_RATE:-200}"
RUN_TIME="${RUN_TIME:-120s}"
EVENT_ID="${EVENT_ID:-evt-001}"
BACKENDS="${BACKENDS:-mysql dynamodb}"
FAIRNESS_MODES="${FAIRNESS_MODES:-allow_multiple collapse}"
GREEDY_JOINS="${GREEDY_JOINS:-3}"
QUEUE_POLL_INTERVAL="${QUEUE_POLL_INTERVAL:-5}"

# ── Directories ───────────────────────────────────────────────────────────────
CSV_DIR="${REPO_ROOT}/.tmp/exp5_locust"
LOG_DIR="${REPO_ROOT}/.tmp/exp5_logs"
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${CSV_DIR}" "${LOG_DIR}" "${RESULTS_DIR}"

# ── Python / Locust detection ─────────────────────────────────────────────────
if command -v python &>/dev/null; then PY="python"
elif command -v python3 &>/dev/null; then PY="python3"
else echo "ERROR: Python not found."; exit 1; fi

if ! command -v locust &>/dev/null; then
    echo "ERROR: locust not found. Run: pip install locust"
    exit 1
fi

# ── Get ALB URL from Terraform ────────────────────────────────────────────────
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
SUMMARY_CSV="${RESULTS_DIR}/exp5_${TIMESTAMP}.csv"

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Reset DB and queue between runs ──────────────────────────────────────────
reset_db() {
    echo "    Resetting booking and inventory data..."
    curl -sf -X POST "${BOOKING_URL}/booking/api/v1/reset" > /dev/null 2>&1 || true

    echo "    Resetting queue state for event ${EVENT_ID}..."
    curl -sf -X POST "${BOOKING_URL}/queue/api/v1/queue/event/${EVENT_ID}/reset" > /dev/null 2>&1 || true

    sleep 3
}

# ── Switch database backend via Terraform ─────────────────────────────────────
switch_backend() {
    local backend=$1
    echo "    Switching backend to: ${backend}..."
    cd "${MAIN_TF}"
    terraform apply -auto-approve -var="db_backend=${backend}" > /dev/null 2>&1
    cd "${REPO_ROOT}"

    # terraform apply completes once ECS considers the service stable (new tasks running).
    # However, the ALB deregistration_delay is 300 s — old tasks (wrong backend) remain
    # registered in the target group and continue receiving traffic until the drain window
    # expires.  We must wait out this window before running tests, otherwise reset_db
    # and booking requests can hit old-backend tasks, contaminating seat_versions data.
    #
    # The health endpoint does NOT expose the active backend, so polling it cannot tell
    # us when all old tasks are gone.  A fixed sleep equal to deregistration_delay + buffer
    # is the only reliable approach.
    local ALB_DRAIN_SECONDS=310
    echo -n "    Waiting ${ALB_DRAIN_SECONDS}s for ALB to drain old ${backend} tasks "
    local elapsed=0
    while [ "$elapsed" -lt "$ALB_DRAIN_SECONDS" ]; do
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo " drained"

    # Verify the booking service is healthy after drain
    echo -n "    Verifying booking service "
    local attempts=0
    until curl -sf "${BOOKING_URL}/booking/health" 2>/dev/null | grep -q "healthy"; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 12 ]; then
            echo ""
            echo "ERROR: Booking service health check timed out after drain"
            exit 1
        fi
        echo -n "."
        sleep 5
    done
    echo " booking ready"

    # Terraform apply may also restart the queue service (ECS rolling deploy).
    # Wait until the queue health endpoint is reachable before proceeding so
    # queue join and status poll requests go to the same in-memory instance.
    echo -n "    Waiting for queue service "
    attempts=0
    until curl -sf "${BOOKING_URL}/queue/health" > /dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 18 ]; then
            echo ""
            echo "ERROR: Queue service health check timed out"
            exit 1
        fi
        echo -n "."
        sleep 10
    done
    echo " queue ready"
}

# ── Set queue fairness mode via the runtime API ───────────────────────────────
set_fairness_mode() {
    local mode=$1
    echo "    Setting fairness mode to: ${mode}..."
    curl -sf -X POST \
        "${BOOKING_URL}/queue/api/v1/queue/event/${EVENT_ID}/fairness-mode" \
        -H "Content-Type: application/json" \
        -d "{\"mode\":\"${mode}\"}" > /dev/null 2>&1 || true
    sleep 1
}

# ── Poll queue metrics in background ─────────────────────────────────────────
poll_queue_metrics() {
    local out_file=$1
    local sentinel=$2
    local snap=0
    > "${out_file}"
    while [ -f "${sentinel}" ]; do
        local result
        result=$(curl -sf "${BOOKING_URL}/queue/api/v1/queue/event/${EVENT_ID}/metrics" \
                 2>/dev/null || echo "{}")
        echo "{\"snapshot\":${snap},\"data\":${result}}" >> "${out_file}"
        snap=$((snap + 1))
        sleep "${QUEUE_POLL_INTERVAL}"
    done
}

# ── Parse Locust CSV — returns multi-line output, one row per endpoint ────────
parse_locust_stats() {
    local csv_prefix=$1
    local stats_file="${csv_prefix}_stats.csv"
    if [ ! -f "${stats_file}" ]; then
        echo "- - - - - - -"
        return
    fi
    $PY "${PARSE_SCRIPT}" "${stats_file}" 2>/dev/null || echo "- - - - - - -"
}

# ── Run one scenario (backend + fairness mode) ────────────────────────────────
run_scenario() {
    local backend=$1
    local mode=$2
    local label="${backend}_${mode}"
    local csv_prefix="${CSV_DIR}/${label}"
    local log_file="${LOG_DIR}/${label}.log"
    local queue_file="${CSV_DIR}/${label}_queue_metrics.jsonl"
    local sentinel="${CSV_DIR}/${label}.sentinel"

    echo ""
    echo "  Running: backend=${backend}  fairness_mode=${mode}"

    set_fairness_mode "${mode}"

    # Start queue metric polling in background
    touch "${sentinel}"
    poll_queue_metrics "${queue_file}" "${sentinel}" &
    POLL_PID=$!

    # Run Locust with both user classes (weighted 40/60 by locustfile)
    locust -f "${LOCUST_FILE}" \
        --host           "${BOOKING_URL}" \
        --headless \
        --users          "${USERS}" \
        --spawn-rate     "${SPAWN_RATE}" \
        --run-time       "${RUN_TIME}" \
        --csv            "${csv_prefix}" \
        --loglevel       WARNING \
        --fairness-mode  "${mode}" \
        --greedy-joins   "${GREEDY_JOINS}" \
        > "${log_file}" 2>&1 || true

    # Stop background metric polling
    rm -f "${sentinel}"
    wait $POLL_PID 2>/dev/null || true
    echo "    Queue metrics saved to: ${queue_file}"

    # ── Parse stats per endpoint ──────────────────────────────────────────────
    local stats_output
    stats_output=$(parse_locust_stats "${csv_prefix}")

    # Extract booking/book row for pass/fail check
    local book_reqs=0 book_fails=0
    while IFS=' ' read -r ep_name avg p50 p95 p99 reqs fails; do
        echo "    [${ep_name}] avg=${avg}ms p50=${p50}ms p95=${p95}ms p99=${p99}ms  req=${reqs} fail=${fails}"
        if [ "${ep_name}" = "booking/book" ]; then
            book_reqs="${reqs:-0}"
            book_fails="${fails:-0}"
        fi
        # Append one CSV row per endpoint
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "${backend}" "${mode}" "${ep_name}" \
            "${reqs}" "${fails}" \
            "${avg}" "${p50}" "${p95}" "${p99}" \
            "${queue_file}" "${GREEDY_JOINS}" >> "${SUMMARY_CSV}"
    done <<< "${stats_output}"

    # Pass/fail on booking failures
    if [ "${book_fails:-0}" = "0" ] 2>/dev/null; then
        ok "${backend}/${mode}: 0 booking failures"
    else
        fail "${backend}/${mode}: ${book_fails} booking failures out of ${book_reqs}"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  Experiment 5 — Multiple Requests from the Same User"
echo "  Booking URL     : ${BOOKING_URL}"
echo "  Backends        : ${BACKENDS}"
echo "  Fairness modes  : ${FAIRNESS_MODES}"
echo "  Users           : ${USERS}  (USERS=N to override)"
echo "  Spawn rate      : ${SPAWN_RATE}/s"
echo "  Run time        : ${RUN_TIME}"
echo "  Event           : ${EVENT_ID}"
echo "  Greedy joins    : ${GREEDY_JOINS}  (GREEDY_JOINS=N to override)"
echo "  User split      : 40% GreedyUser / 60% FairUser"
echo "=============================================================="
echo ""
echo "  WHAT THIS MEASURES"
echo "  allow_multiple: each greedy user occupies ${GREEDY_JOINS} queue slots,"
echo "    gaining an unfair advantage over single-join fair users."
echo "  collapse: the server deduplicates per-IP — greedy users are"
echo "    reduced to 1 slot, equal to fair users."
echo "  Key metrics: booking success rate per cohort, queue depth,"
echo "    and the fairness ratio (greedy success / fair success)."
echo "=============================================================="
echo ""

# ── Health checks ─────────────────────────────────────────────────────────────
echo "--- [1] Health checks"
for svc in inventory booking queue; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${BOOKING_URL}/${svc}/health")
    if [ "$HTTP" = "200" ]; then ok "${svc}-service /health (HTTP 200)"
    else fail "${svc}-service /health (expected 200, got ${HTTP})"; fi
done

# ── Write CSV header ──────────────────────────────────────────────────────────
printf "backend,fairness_mode,endpoint,requests,failures,avg_ms,p50_ms,p95_ms,p99_ms,queue_metrics_file,greedy_joins\n" \
    > "${SUMMARY_CSV}"

# ── Run all backend × fairness-mode combinations ─────────────────────────────
IDX=2
for backend in ${BACKENDS}; do
    echo ""
    echo "=============================================================="
    echo "  Backend: ${backend}"
    echo "=============================================================="

    switch_backend "${backend}"

    for mode in ${FAIRNESS_MODES}; do
        echo ""
        echo "--- [${IDX}] ${backend} / fairness_mode=${mode}"
        reset_db
        run_scenario "${backend}" "${mode}"
        IDX=$(( IDX + 1 ))
    done
done

# ── Summary table (booking/book rows only) ────────────────────────────────────
echo ""
echo "=============================================================="
echo "  BOOKING RESULTS SUMMARY  (booking/book endpoint)"
echo "=============================================================="
printf "  %-10s %-16s %8s %8s %8s %7s %7s %7s\n" \
    "Backend" "Fairness Mode" "Requests" "Failures" "Avg(ms)" "p50" "p95" "p99"
printf "  %-10s %-16s %8s %8s %8s %7s %7s %7s\n" \
    "-------" "-------------" "--------" "--------" "-------" "---" "---" "---"

grep ",booking/book," "${SUMMARY_CSV}" | tail -n +1 | \
while IFS=',' read -r backend mode ep reqs fails avg p50 p95 p99 qfile gjoins; do
    printf "  %-10s %-16s %8s %8s %8s %7s %7s %7s\n" \
        "${backend}" "${mode}" "${reqs}" "${fails}" "${avg}" "${p50}" "${p95}" "${p99}"
done

echo ""
echo "  Tests passed: ${PASS}  |  Tests failed: ${FAIL}"
echo "=============================================================="
echo ""
echo "  Results CSV   : ${SUMMARY_CSV}"
echo "  Locust logs   : ${LOG_DIR}/"
echo "  Queue metrics : ${CSV_DIR}/*_queue_metrics.jsonl"

# ── Generate plots ────────────────────────────────────────────────────────────
SUMMARY_PNG="${RESULTS_DIR}/exp5_${TIMESTAMP}.png"
echo ""
echo "--- Generating plots..."
if $PY "${CHART_SCRIPT}" "${SUMMARY_CSV}" "${SUMMARY_PNG}" 2>&1; then
    echo "  Plots saved   : ${SUMMARY_PNG}"
else
    echo "  WARNING: plot generation failed (pip install matplotlib numpy to enable)"
fi
echo ""
echo "  Tip: compare greedy vs fair cohort success rates from the"
echo "  [Experiment 5] summary printed at the end of each Locust run"
echo "  in the log files under ${LOG_DIR}/"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "  Check logs for failures:"
    echo "  aws logs tail /ecs/concert-platform-booking --follow --region us-east-1"
    exit 1
fi

echo "All experiment 5 tests passed."
