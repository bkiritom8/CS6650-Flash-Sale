"""
generate_chart.py — generates the Experiment 1 results PNG from a CSV file.

Called by exp1-locust-test.sh — replaces the heredoc approach which
is unreliable on Windows Git Bash.

Usage:
    python generate_chart.py <results_csv> <output_png> <concurrency>

Requires: matplotlib, numpy
    pip install matplotlib numpy
"""
import sys
import csv
import matplotlib.pyplot as plt
import numpy as np


def main():
    if len(sys.argv) < 4:
        print("Usage: generate_chart.py <csv> <png> <concurrency>")
        sys.exit(1)

    csv_path, png_path, concurrency = sys.argv[1], sys.argv[2], int(sys.argv[3])

    data = []
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            data.append(row)

    if not data:
        print("No data found in CSV")
        sys.exit(1)

    labels    = [f"{r['backend']}\n{r['lock_mode']}" for r in data]
    legit     = [int(r['legitimate'])  for r in data]
    oversells = [int(r['oversells'])   for r in data]
    failed    = [int(r['failed'])      for r in data]

    def safe_int(v):
        try:
            return int(v)
        except (ValueError, TypeError):
            return 0

    p50 = [safe_int(r.get('p50_ms')) for r in data]
    p95 = [safe_int(r.get('p95_ms')) for r in data]
    p99 = [safe_int(r.get('p99_ms')) for r in data]

    mysql_idx  = [i for i, r in enumerate(data) if r['backend'] == 'mysql']
    dynamo_idx = [i for i, r in enumerate(data) if r['backend'] == 'dynamodb']
    mode_labels = [data[i]['lock_mode'] for i in mysql_idx]

    fig = plt.figure(figsize=(16, 7))
    fig.suptitle(
        f"Experiment 1 — Locking Strategy Benchmark ({concurrency} users, 1 seat)",
        fontsize=14, fontweight='bold', y=1.01
    )

    # ── Stacked outcomes ──────────────────────────────────────────────────────
    ax1 = fig.add_subplot(1, 3, 1)
    x = np.arange(len(labels))
    w = 0.5
    ax1.bar(x, legit,     w, label='Legitimate', color='#2ecc71')
    ax1.bar(x, oversells, w, bottom=legit, label='Oversells', color='#e74c3c')
    ax1.bar(x, failed,    w,
            bottom=[l + o for l, o in zip(legit, oversells)],
            label='Failed', color='#bdc3c7')
    ax1.axhline(concurrency, color='black', linewidth=0.8, linestyle='--',
                label=f'{concurrency} users')
    ax1.set_yscale('function',
                   functions=(lambda x: np.sqrt(np.maximum(x, 0)), lambda x: x ** 2))
    ax1.set_ylim(0, concurrency * 1.1)
    yticks = [t for t in
              [1, 10, 50, 100, 250, 500, 750, 1000, 2000, 5000, 10000, 50000, 100000]
              if t <= concurrency * 1.1]
    ax1.set_yticks(yticks)
    ax1.set_yticklabels([str(t) for t in yticks])
    ax1.set_title("Booking Outcomes (sqrt scale)")
    ax1.set_ylabel("Requests (sqrt scale)")
    ax1.set_xticks(x)
    ax1.set_xticklabels(labels, fontsize=8)
    ax1.legend(loc='upper right', fontsize=8, framealpha=0.9)
    for i, (l, o, fa) in enumerate(zip(legit, oversells, failed)):
        if l > 0:
            ax1.text(i, l, str(l), ha='center', va='bottom',
                     fontsize=7, color='#27ae60', fontweight='bold')
        if o > 0:
            ax1.text(i, l + o, str(o), ha='center', va='bottom',
                     fontsize=7, color='#c0392b', fontweight='bold')
        if fa > 0:
            ax1.text(i, l + o + fa, str(fa), ha='center', va='bottom',
                     fontsize=7, color='#7f8c8d', fontweight='bold')

    def latency_chart(ax, idx, title):
        xv = np.arange(len(idx))
        bw = 0.25
        b50 = ax.bar(xv - bw, [p50[i] for i in idx], bw, label='p50', color='#3498db')
        b95 = ax.bar(xv,      [p95[i] for i in idx], bw, label='p95', color='#e67e22')
        b99 = ax.bar(xv + bw, [p99[i] for i in idx], bw, label='p99', color='#9b59b6')
        ax.set_title(title)
        ax.set_ylabel("Latency (ms)")
        ax.set_xticks(xv)
        ax.set_xticklabels(mode_labels, fontsize=9)
        ax.legend(fontsize=8, loc='upper right', framealpha=0.9)
        max_v = max([p99[i] for i in idx] + [1])
        ax.set_ylim(0, max_v * 1.4)
        for bars in [b50, b95, b99]:
            for bar in bars:
                h = bar.get_height()
                if h > 0:
                    ax.text(bar.get_x() + bar.get_width() / 2,
                            h + max_v * 0.01, str(h),
                            ha='left', va='bottom', fontsize=7, rotation=45)

    if mysql_idx:
        latency_chart(fig.add_subplot(1, 3, 2), mysql_idx, "MySQL — Latency (ms)")
    if dynamo_idx:
        latency_chart(fig.add_subplot(1, 3, 3), dynamo_idx, "DynamoDB — Latency (ms)")

    plt.tight_layout()
    plt.savefig(png_path, dpi=150, bbox_inches='tight')
    print(f"Chart saved to {png_path}")


if __name__ == "__main__":
    main()