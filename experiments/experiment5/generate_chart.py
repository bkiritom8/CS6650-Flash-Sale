"""
generate_chart.py — generates the Experiment 5 results PNG from a CSV file.

CSV columns (written by exp5-locust-test.sh):
    backend, fairness_mode, endpoint, requests, failures,
    avg_ms, p50_ms, p95_ms, p99_ms, queue_metrics_file, greedy_joins

Usage:
    python generate_chart.py <results_csv> <output_png>

Requires: matplotlib, numpy
    pip install matplotlib numpy
"""
import sys
import csv
import json
import os
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np


ENDPOINTS = ["queue/join", "queue/status", "booking/book"]
COLORS = {
    "mysql":    {"allow_multiple": "#e74c3c", "collapse": "#c0392b"},
    "dynamodb": {"allow_multiple": "#3498db", "collapse": "#1a6fa0"},
}
FAIRNESS_LABELS = {"allow_multiple": "allow_multiple", "collapse": "collapse"}


def safe_int(v):
    try:
        return int(float(v))
    except (ValueError, TypeError):
        return 0


def load_csv(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows


def load_queue_metrics(path):
    """Return list of dicts from a .jsonl queue-metrics file."""
    snapshots = []
    if not path or not os.path.isfile(path):
        return snapshots
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    snapshots.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return snapshots


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_chart.py <results_csv> <output_png>")
        sys.exit(1)

    csv_path, png_path = sys.argv[1], sys.argv[2]
    rows = load_csv(csv_path)
    if not rows:
        print("No data found in CSV")
        sys.exit(1)

    # ── Index rows by (backend, fairness_mode, endpoint) ─────────────────────
    data = {}
    for r in rows:
        key = (r["backend"], r["fairness_mode"], r["endpoint"])
        data[key] = r

    backends      = sorted({r["backend"]       for r in rows})
    fairness_modes = sorted({r["fairness_mode"] for r in rows},
                            key=lambda m: (m != "allow_multiple"))  # allow_multiple first
    scenarios     = [(b, m) for b in backends for m in fairness_modes]
    scenario_labels = [f"{b}\n{m}" for b, m in scenarios]

    def get(backend, mode, endpoint, field, default=0):
        r = data.get((backend, mode, endpoint))
        if r is None:
            return default
        return safe_int(r.get(field, default))

    # ── Figure layout: 2×2 ────────────────────────────────────────────────────
    fig, axes = plt.subplots(2, 2, figsize=(16, 11))
    fig.suptitle(
        "Experiment 5 — Multiple Requests from the Same User\n"
        "Fairness: allow_multiple vs collapse",
        fontsize=14, fontweight="bold",
    )

    x   = np.arange(len(scenarios))
    w   = 0.35
    bar_colors = ["#e74c3c", "#c0392b", "#3498db", "#1a6fa0"]  # one per scenario

    # ── Plot 1: Booking success vs failure (booking/book endpoint) ────────────
    ax = axes[0, 0]
    book_reqs  = [get(b, m, "booking/book", "requests")  for b, m in scenarios]
    book_fails = [get(b, m, "booking/book", "failures")  for b, m in scenarios]
    book_ok    = [max(r - f, 0) for r, f in zip(book_reqs, book_fails)]

    bars_ok   = ax.bar(x - w/2, book_ok,    w, label="Success",  color="#2ecc71")
    bars_fail = ax.bar(x + w/2, book_fails, w, label="Failures", color="#e74c3c")

    for bar in bars_ok:
        h = bar.get_height()
        if h > 0:
            ax.text(bar.get_x() + bar.get_width()/2, h + 1, str(h),
                    ha="center", va="bottom", fontsize=7, color="#27ae60", fontweight="bold")
    for bar in bars_fail:
        h = bar.get_height()
        if h > 0:
            ax.text(bar.get_x() + bar.get_width()/2, h + 1, str(h),
                    ha="center", va="bottom", fontsize=7, color="#c0392b", fontweight="bold")

    ax.set_title("Booking Outcomes (booking/book)", fontsize=11)
    ax.set_ylabel("Request count")
    ax.set_xticks(x)
    ax.set_xticklabels(scenario_labels, fontsize=8)
    ax.legend(fontsize=9)
    ax.yaxis.set_major_locator(mticker.MaxNLocator(integer=True))

    # ── Plot 2: Fairness ratio — success rate greedy vs fair ──────────────────
    # Derived from queue join counts used per cohort (approx via total reqs).
    # Since cohorts aren't split in the CSV, we use failure rates as proxy:
    #   success_rate ≈ (requests - failures) / requests
    ax = axes[0, 1]

    success_rates = []
    for b, m in scenarios:
        reqs  = get(b, m, "booking/book", "requests")
        fails = get(b, m, "booking/book", "failures")
        rate  = (reqs - fails) / reqs * 100 if reqs > 0 else 0
        success_rates.append(rate)

    bars = ax.bar(x, success_rates, 0.5, color=bar_colors[:len(scenarios)])
    ax.axhline(100, color="gray", linewidth=0.8, linestyle="--", label="100%")

    for bar, rate in zip(bars, success_rates):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                f"{rate:.1f}%", ha="center", va="bottom", fontsize=8, fontweight="bold")

    ax.set_title("Booking Success Rate by Scenario", fontsize=11)
    ax.set_ylabel("Success rate (%)")
    ax.set_ylim(0, 115)
    ax.set_xticks(x)
    ax.set_xticklabels(scenario_labels, fontsize=8)
    ax.legend(fontsize=9)

    # ── Plot 3: Latency percentiles for booking/book ──────────────────────────
    ax = axes[1, 0]
    bw = 0.18
    p50 = [get(b, m, "booking/book", "p50_ms") for b, m in scenarios]
    p95 = [get(b, m, "booking/book", "p95_ms") for b, m in scenarios]
    p99 = [get(b, m, "booking/book", "p99_ms") for b, m in scenarios]
    avg = [get(b, m, "booking/book", "avg_ms") for b, m in scenarios]

    b_avg = ax.bar(x - 1.5*bw, avg, bw, label="avg",  color="#95a5a6")
    b_p50 = ax.bar(x - 0.5*bw, p50, bw, label="p50",  color="#3498db")
    b_p95 = ax.bar(x + 0.5*bw, p95, bw, label="p95",  color="#e67e22")
    b_p99 = ax.bar(x + 1.5*bw, p99, bw, label="p99",  color="#9b59b6")

    max_v = max(p99 + [1])
    for bars_grp in [b_avg, b_p50, b_p95, b_p99]:
        for bar in bars_grp:
            h = bar.get_height()
            if h > 0:
                ax.text(bar.get_x() + bar.get_width()/2,
                        h + max_v * 0.01, str(h),
                        ha="center", va="bottom", fontsize=6, rotation=60)

    ax.set_title("booking/book Latency by Scenario (ms)", fontsize=11)
    ax.set_ylabel("Latency (ms)")
    ax.set_ylim(0, max_v * 1.5)
    ax.set_xticks(x)
    ax.set_xticklabels(scenario_labels, fontsize=8)
    ax.legend(fontsize=9)

    # ── Plot 4: Queue depth over time (from .jsonl metrics files) ─────────────
    ax = axes[1, 1]
    plotted_any = False

    line_styles = ["-", "--", "-.", ":"]
    line_colors = ["#e74c3c", "#c0392b", "#3498db", "#1a6fa0"]

    for idx, (b, m) in enumerate(scenarios):
        # Find queue_metrics_file from any row for this scenario
        qfile = None
        for r in rows:
            if r["backend"] == b and r["fairness_mode"] == m:
                qfile = r.get("queue_metrics_file", "")
                break

        snapshots = load_queue_metrics(qfile)
        if not snapshots:
            continue

        depths = []
        for snap in snapshots:
            d = snap.get("data", {})
            # Support both {"queue_depth": N} and nested structures
            if isinstance(d, dict):
                depth = (d.get("queue_depth") or
                         d.get("depth") or
                         d.get("size") or
                         d.get("waiting") or 0)
            else:
                depth = 0
            depths.append(safe_int(depth))

        if depths:
            t = list(range(len(depths)))
            ax.plot(t, depths,
                    label=f"{b}/{m}",
                    color=line_colors[idx % len(line_colors)],
                    linestyle=line_styles[idx % len(line_styles)],
                    linewidth=1.8)
            plotted_any = True

    if not plotted_any:
        ax.text(0.5, 0.5, "Queue metrics not available\n(run the experiment to populate)",
                ha="center", va="center", transform=ax.transAxes,
                fontsize=10, color="gray")

    ax.set_title("Queue Depth Over Time", fontsize=11)
    ax.set_xlabel("Poll snapshot #")
    ax.set_ylabel("Queue depth")
    if plotted_any:
        ax.legend(fontsize=9)

    plt.tight_layout()
    plt.savefig(png_path, dpi=150, bbox_inches="tight")
    print(f"Chart saved to {png_path}")


if __name__ == "__main__":
    main()
