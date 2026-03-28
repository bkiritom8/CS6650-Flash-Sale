#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCUST_FILE="${REPO_ROOT}/experiments/experiment1/experiment1.py"
EXP_TF="${REPO_ROOT}/experiments/experiment1/terraform"

# ── Tunable parameters ─────────────────────────────────────────────────────────
CONCURRENCY="${CONCURRENCY:-100000}"
SPAWN_RATE="${SPAWN_RATE:-10000}"
RUN_TIME="${RUN_TIME:-60s}"
MAX_RETRIES="${MAX_RETRIES:-3}"
# Space-separated list of backends to test
BACKENDS="${BACKENDS:-mysql dynamodb}"

PASS=0
FAIL=0
CSV_DIR="${TMPDIR:-/tmp}/exp1_locust"
mkdir -p "${CSV_DIR}"

# ── Prerequisites ──────────────────────────────────────────────────────────────
if command -v python3 &>/dev/null; then PY="python3"
elif command -v python  &>/dev/null; then PY="python"
else echo "ERROR: Python not found."; exit 1; fi

if ! command -v locust &>/dev/null; then
    echo "ERROR: locust not found.  Run: pip install -r experiments/experiment1/requirements.txt"
    exit 1
fi

# ── Get experiment1 service URL ────────────────────────────────────────────────
cd "${EXP_TF}"
if ! terraform output experiment1_url > /dev/null 2>&1; then
    echo ""
    echo "ERROR: Experiment 1 service is not deployed."
    echo "Run: bash experiments/experiment1/scripts/deploy.sh"
    exit 1
fi
EXP1_URL=$(terraform output -raw experiment1_url)

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Results table storage ──────────────────────────────────────────────────────
declare -a RES_BACKEND RES_MODE RES_BOOKINGS RES_OVERSELLS RES_FAILED RES_LEGIT \
           RES_AVG RES_P50 RES_P95 RES_P99 RES_STATUS

# ── parse_latency <csv_prefix> — sets LAT_AVG LAT_P50 LAT_P95 LAT_P99 ─────────
parse_latency() {
    local prefix="$1"
    local stats_csv="${prefix}_stats.csv"
    LAT_AVG="-"; LAT_P50="-"; LAT_P95="-"; LAT_P99="-"
    [ -f "${stats_csv}" ] || return
    read -r LAT_AVG LAT_P50 LAT_P95 LAT_P99 < <($PY - <<PYEOF 2>/dev/null || true
import csv
with open("${stats_csv}") as f:
    for row in csv.DictReader(f):
        if "/seat/book" in row.get("Name", ""):
            avg = round(float(row.get("Average Response Time", 0)))
            p50 = row.get("50%", "-")
            p95 = row.get("95%", "-")
            p99 = row.get("99%", "-")
            print(avg, p50, p95, p99)
            break
PYEOF
)
}

# ── run_mode <backend> <lock_mode> ────────────────────────────────────────────
run_mode() {
    local backend=$1 mode=$2
    local event_id seat_id result bookings oversells
    local csv_prefix="${CSV_DIR}/${backend}_${mode}"

    seat_id="seat-last"
    event_id="exp1-$($PY -c 'import uuid; print(uuid.uuid4().hex[:8])')"

    printf "  %-10s %-14s  event=%-18s " "${backend}" "${mode}" "${event_id}"

    # 1. Init seat
    if ! curl -sf -X POST "${EXP1_URL}/api/v1/seat/init" \
        -H "Content-Type: application/json" \
        -d "{\"event_id\":\"${event_id}\",\"seat_id\":\"${seat_id}\",\"db_backend\":\"${backend}\"}" \
        > /dev/null 2>&1; then
        echo "INIT FAILED"
        fail "${backend}/${mode}: seat init failed"
        RES_BACKEND+=("${backend}"); RES_MODE+=("${mode}")
        RES_BOOKINGS+=("-"); RES_OVERSELLS+=("-")
        RES_AVG+=("-"); RES_P50+=("-"); RES_P95+=("-"); RES_P99+=("-")
        RES_STATUS+=("INIT_FAILED")
        return
    fi

    # 2. Run Locust with CSV output for latency stats
    locust -f "${LOCUST_FILE}" \
        --host        "${EXP1_URL}" \
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
        2>/dev/null || true

    # 3. Fetch ground-truth results from the server
    result=$(curl -sf \
        "${EXP1_URL}/api/v1/seat/results?event_id=${event_id}&seat_id=${seat_id}&db_backend=${backend}" \
        || echo "{}")
    bookings=$(echo  "$result" | $PY -c "import sys,json; print(json.load(sys.stdin).get('booking_count',  0))" 2>/dev/null || echo 0)
    oversells=$(echo "$result" | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count', 0))" 2>/dev/null || echo 0)

    # 4. Parse latency from CSV
    parse_latency "${csv_prefix}"

    # 5. Cleanup
    curl -sf -X DELETE \
        "${EXP1_URL}/api/v1/seat?event_id=${event_id}&seat_id=${seat_id}&db_backend=${backend}" \
        > /dev/null 2>&1 || true

    # 6. Correctness assertion
    local status
    case "${mode}" in
        none)
            if [ "${oversells:-0}" -gt 0 ] 2>/dev/null; then
                status="PASS"
                ok "${backend}/${mode}: bookings=${bookings}  oversells=${oversells}  avg=${LAT_AVG}ms"
            else
                status="FAIL-expected-oversells"
                fail "${backend}/${mode}: expected oversells, got 0 (bookings=${bookings})"
            fi
            ;;
        optimistic|pessimistic)
            if [ "${oversells:-1}" -eq 0 ] 2>/dev/null; then
                status="PASS"
                ok "${backend}/${mode}: bookings=${bookings}  oversells=${oversells}  avg=${LAT_AVG}ms"
            else
                status="FAIL-oversells=${oversells}"
                fail "${backend}/${mode}: expected 0 oversells, got ${oversells}"
            fi
            ;;
        *)
            status="UNKNOWN"
            ;;
    esac

    # failed = users that never wrote a booking (connection errors, timeouts)
    # legitimate = bookings that were not oversells (should be 1 for opt/pess, ~1 for none)
    local failed=$(( CONCURRENCY - bookings ))
    local legitimate=$(( bookings - oversells ))

    RES_BACKEND+=("${backend}"); RES_MODE+=("${mode}")
    RES_BOOKINGS+=("${bookings}"); RES_OVERSELLS+=("${oversells}")
    RES_FAILED+=("${failed}"); RES_LEGIT+=("${legitimate}")
    RES_AVG+=("${LAT_AVG}"); RES_P50+=("${LAT_P50}")
    RES_P95+=("${LAT_P95}"); RES_P99+=("${LAT_P99}")
    RES_STATUS+=("${status}")
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  Experiment 1 — Locking Strategy Benchmark"
echo "  Service URL : ${EXP1_URL}"
echo "  Backends    : ${BACKENDS}"
echo "  Concurrency : ${CONCURRENCY} users  (CONCURRENCY=N to override)"
echo "  Spawn rate  : ${SPAWN_RATE}/s        (SPAWN_RATE=N to override)"
echo "  Run time    : ${RUN_TIME}             (RUN_TIME=Xs to override)"
echo "  Strategy    : waiting-room (all users spawn, then rush together)"
echo "=============================================================="

# ── [1] Health ─────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health check"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${EXP1_URL}/health")
if [ "$HTTP" = "200" ]; then ok "GET /health (HTTP 200)"
else fail "GET /health (expected 200, got ${HTTP})"; fi

# ── [2-N] Run all backend × mode combinations ──────────────────────────────────
IDX=2
for backend in ${BACKENDS}; do
    for mode in none optimistic pessimistic; do
        echo ""
        echo "--- [${IDX}] ${backend} / ${mode}"
        run_mode "${backend}" "${mode}"
        IDX=$((IDX + 1))
    done
done

# ── Results table ──────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  RESULTS SUMMARY  (${CONCURRENCY} users · waiting-room spawn)"
echo "=============================================================="
printf "  %-10s %-14s %9s %10s %8s %7s %8s %7s %7s %7s  %s\n" \
    "Backend" "Lock Mode" "Bookings" "Oversells" "Legit" "Failed" "Avg(ms)" "p50" "p95" "p99" "Status"
printf "  %-10s %-14s %9s %10s %8s %7s %8s %7s %7s %7s  %s\n" \
    "--------" "----------" "--------" "---------" "-----" "------" "-------" "---" "---" "---" "------"
echo "  (Bookings = Legit + Oversells  |  Legit + Oversells + Failed = ${CONCURRENCY} users)"
for i in "${!RES_MODE[@]}"; do
    printf "  %-10s %-14s %9s %10s %8s %7s %8s %7s %7s %7s  %s\n" \
        "${RES_BACKEND[$i]}" "${RES_MODE[$i]}" \
        "${RES_BOOKINGS[$i]}" "${RES_OVERSELLS[$i]}" "${RES_LEGIT[$i]}" "${RES_FAILED[$i]}" \
        "${RES_AVG[$i]}" "${RES_P50[$i]}" "${RES_P95[$i]}" "${RES_P99[$i]}" \
        "${RES_STATUS[$i]}"
done
echo ""
echo "  Tests passed: ${PASS}  |  Tests failed: ${FAIL}"
echo "=============================================================="

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "  Check experiment1 logs:"
    echo "  aws logs tail /ecs/concert-platform-experiment1 --follow --region us-east-1"
    echo ""
fi

# ── Save results to CSV ────────────────────────────────────────────────────────
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_CSV="${RESULTS_DIR}/exp1_${TIMESTAMP}.csv"

printf "backend,lock_mode,concurrency,bookings,oversells,legitimate,failed,avg_ms,p50_ms,p95_ms,p99_ms,status\n" > "${OUT_CSV}"
for i in "${!RES_MODE[@]}"; do
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "${RES_BACKEND[$i]}" "${RES_MODE[$i]}" "${CONCURRENCY}" \
        "${RES_BOOKINGS[$i]}" "${RES_OVERSELLS[$i]}" "${RES_LEGIT[$i]}" "${RES_FAILED[$i]}" \
        "${RES_AVG[$i]}" "${RES_P50[$i]}" "${RES_P95[$i]}" "${RES_P99[$i]}" \
        "${RES_STATUS[$i]}" >> "${OUT_CSV}"
done

echo ""
echo "  Results saved to: ${OUT_CSV}"

# ── Generate PNG visualisation ─────────────────────────────────────────────────
OUT_PNG="${OUT_CSV%.csv}.png"
$PY - "${OUT_CSV}" "${OUT_PNG}" "${CONCURRENCY}" <<'PYEOF' 2>/dev/null && echo "  Chart saved to:   ${OUT_PNG}" || echo "  (chart generation skipped — pip install matplotlib to enable)"
import sys, csv
import matplotlib.pyplot as plt
import numpy as np

csv_path, png_path, concurrency = sys.argv[1], sys.argv[2], int(sys.argv[3])

data = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        data.append(row)

labels    = [f"{r['backend']}\n{r['lock_mode']}" for r in data]
legit     = [int(r['legitimate'])  for r in data]
oversells = [int(r['oversells'])   for r in data]
failed    = [int(r['failed'])      for r in data]
p50 = [int(r['p50_ms']) if r.get('p50_ms','') not in ('-','') else 0 for r in data]
p95 = [int(r['p95_ms']) if r.get('p95_ms','') not in ('-','') else 0 for r in data]
p99 = [int(r['p99_ms']) if r.get('p99_ms','') not in ('-','') else 0 for r in data]

x = np.arange(len(labels))
fig, axes = plt.subplots(1, 2, figsize=(14, 6))
fig.suptitle(f"Experiment 1 — Locking Strategy Benchmark ({concurrency} users, 1 seat)", fontsize=14, fontweight='bold')

ax = axes[0]
ax.bar(x, legit,     0.55, label='Legitimate booking',           color='#2ecc71')
ax.bar(x, oversells, 0.55, bottom=legit, label='Oversells',      color='#e74c3c')
ax.bar(x, failed,    0.55, bottom=[l+o for l,o in zip(legit,oversells)], label='Failed (never reached DB)', color='#bdc3c7')
ax.axhline(concurrency, color='black', linewidth=0.8, linestyle='--', label=f'Total users ({concurrency})')
ax.set_title("Booking Outcomes per Strategy")
ax.set_ylabel("Requests")
ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=9)
ax.legend(fontsize=8); ax.set_ylim(0, concurrency * 1.1)
for i, (l, o) in enumerate(zip(legit, oversells)):
    if o > 0:
        ax.text(i, l + o/2, str(o), ha='center', va='center', fontsize=7, color='white', fontweight='bold')

ax2 = axes[1]
w = 0.2
ax2.bar(x - w, p50, w, label='p50', color='#3498db')
ax2.bar(x,     p95, w, label='p95', color='#e67e22')
ax2.bar(x + w, p99, w, label='p99', color='#9b59b6')
ax2.set_title("Latency by Strategy (ms)")
ax2.set_ylabel("Latency (ms)")
ax2.set_xticks(x); ax2.set_xticklabels(labels, fontsize=9)
ax2.legend(fontsize=8)

plt.tight_layout()
plt.savefig(png_path, dpi=150, bbox_inches='tight')
PYEOF

echo ""

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "All experiment 1 tests passed."
