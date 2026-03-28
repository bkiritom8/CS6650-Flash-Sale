#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCUST_FILE="${REPO_ROOT}/experiments/experiment1/experiment1.py"
MAIN_TF="${REPO_ROOT}/terraform/main"

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

# ── Get booking service URL from main terraform ────────────────────────────────
cd "${MAIN_TF}"
if ! terraform output alb_dns_name > /dev/null 2>&1; then
    echo ""
    echo "ERROR: Main platform is not deployed."
    echo "Run: bash scripts/deploy.sh"
    exit 1
fi
ALB=$(terraform output -raw alb_dns_name)
BOOKING_URL="http://${ALB}"

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

    # 1. Run Locust with CSV output for latency stats
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
        2>/dev/null || true

    # 2. Fetch ground-truth results from booking-service
    bookings=$(curl -sf \
        "${BOOKING_URL}/booking/api/v1/events/${event_id}/bookings" \
        | $PY -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    oversells=$(curl -sf \
        "${BOOKING_URL}/booking/api/v1/metrics?event_id=${event_id}&db_backend=${backend}" \
        | $PY -c "import sys,json; print(json.load(sys.stdin).get('oversell_count', 0))" 2>/dev/null || echo 0)

    # 3. Parse latency from CSV
    parse_latency "${csv_prefix}"

    # 4. Cleanup
    curl -sf -X DELETE \
        "${BOOKING_URL}/booking/api/v1/internal/events/${event_id}/data?db_backend=${backend}" \
        > /dev/null 2>&1 || true

    # 5. Correctness assertion
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
echo "  Booking URL : ${BOOKING_URL}"
echo "  Backends    : ${BACKENDS}"
echo "  Concurrency : ${CONCURRENCY} users  (CONCURRENCY=N to override)"
echo "  Spawn rate  : ${SPAWN_RATE}/s        (SPAWN_RATE=N to override)"
echo "  Run time    : ${RUN_TIME}             (RUN_TIME=Xs to override)"
echo "  Strategy    : waiting-room (all users spawn, then rush together)"
echo "=============================================================="

# ── [1] Health ─────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Health check"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${BOOKING_URL}/booking/health")
if [ "$HTTP" = "200" ]; then ok "GET /booking/health (HTTP 200)"
else fail "GET /booking/health (expected 200, got ${HTTP})"; fi

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
    echo "  Check booking-service logs:"
    echo "  aws logs tail /ecs/concert-platform-booking --follow --region us-east-1"
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

mysql_idx  = [i for i,r in enumerate(data) if r['backend']=='mysql']
dynamo_idx = [i for i,r in enumerate(data) if r['backend']=='dynamodb']
mode_labels = [data[i]['lock_mode'] for i in mysql_idx]

fig = plt.figure(figsize=(16, 7))
fig.suptitle(f"Experiment 1 — Locking Strategy Benchmark ({concurrency} users, 1 seat)",
             fontsize=14, fontweight='bold', y=1.01)

# ── Left: stacked outcomes ────────────────────────────────────────────────────
ax1 = fig.add_subplot(1, 3, 1)
x = np.arange(len(labels))
w = 0.5
ax1.bar(x, legit,     w, label='Legitimate', color='#2ecc71')
ax1.bar(x, oversells, w, bottom=legit, label='Oversells', color='#e74c3c')
ax1.bar(x, failed,    w, bottom=[l+o for l,o in zip(legit,oversells)], label='Failed', color='#bdc3c7')
ax1.axhline(concurrency, color='black', linewidth=0.8, linestyle='--', label=f'{concurrency} users')
ax1.set_yscale('function', functions=(lambda x: np.sqrt(np.maximum(x, 0)), lambda x: x**2))
ax1.set_ylim(0, concurrency * 1.1)
yticks = [t for t in [1, 10, 50, 100, 250, 500, 750, 1000, 2000, 5000, 10000, 50000, 100000] if t <= concurrency * 1.1]
ax1.set_yticks(yticks); ax1.set_yticklabels([str(t) for t in yticks])
ax1.set_title("Booking Outcomes (sqrt scale)")
ax1.set_ylabel("Requests (sqrt scale)")
ax1.set_xticks(x); ax1.set_xticklabels(labels, fontsize=8)
ax1.legend(loc='upper right', fontsize=8, framealpha=0.9)
for i, (l, o, fa) in enumerate(zip(legit, oversells, failed)):
    if l > 0:
        ax1.text(i, l, str(l), ha='center', va='bottom', fontsize=7, color='#27ae60', fontweight='bold')
    if o > 0:
        ax1.text(i, l + o, str(o), ha='center', va='bottom', fontsize=7, color='#c0392b', fontweight='bold')
    if fa > 0:
        ax1.text(i, l + o + fa, str(fa), ha='center', va='bottom', fontsize=7, color='#7f8c8d', fontweight='bold')

def latency_chart(ax, idx, title):
    xv = np.arange(len(idx))
    bw = 0.25
    b50 = ax.bar(xv - bw, [p50[i] for i in idx], bw, label='p50', color='#3498db')
    b95 = ax.bar(xv,      [p95[i] for i in idx], bw, label='p95', color='#e67e22')
    b99 = ax.bar(xv + bw, [p99[i] for i in idx], bw, label='p99', color='#9b59b6')
    ax.set_title(title); ax.set_ylabel("Latency (ms)")
    ax.set_xticks(xv); ax.set_xticklabels(mode_labels, fontsize=9)
    ax.legend(fontsize=8, loc='upper right', framealpha=0.9)
    max_v = max([p99[i] for i in idx] + [1])
    ax.set_ylim(0, max_v * 1.4)
    for bars in [b50, b95, b99]:
        for bar in bars:
            h = bar.get_height()
            if h > 0:
                ax.text(bar.get_x() + bar.get_width()/2, h + max_v*0.01,
                        str(h), ha='left', va='bottom', fontsize=7, rotation=45)

latency_chart(fig.add_subplot(1, 3, 2), mysql_idx,  "MySQL — Latency (ms)")
latency_chart(fig.add_subplot(1, 3, 3), dynamo_idx, "DynamoDB — Latency (ms)")

plt.tight_layout()
plt.savefig(png_path, dpi=150, bbox_inches='tight')
PYEOF

echo ""

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "All experiment 1 tests passed."
