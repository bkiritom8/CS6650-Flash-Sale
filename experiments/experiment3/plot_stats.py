"""
plot_stats.py

Compares multiple load-test configurations across request types.

Usage:
    python plot_stats.py results_*.csv

The script:
  1. Groups CSVs by configuration name (everything before _run<N>).
  2. Averages numeric columns across runs within each configuration.
  3. Produces one figure per request type (rows = metrics, cols = configs),
     plus a summary figure with grouped bar charts for quick cross-config comparison.

Output PNGs are written to the same directory as the script (or cwd).
"""

import sys
import re
import glob
from collections import defaultdict
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np


# ── configuration ────────────────────────────────────────────────────────────

METRICS = {
    "Average Response Time": "Average (ms)",
    "50%":  "p50 (ms)",
    "95%":  "p95 (ms)",
    "99%":  "p99 (ms)",
}

# Rows to skip (Locust adds an "Aggregated" summary row)
SKIP_NAMES = {"Aggregated"}

# Colour palette – one per configuration (up to 8)
PALETTE = [
    "#4C72B0", "#DD8452", "#55A868", "#C44E52",
    "#8172B2", "#937860", "#DA8BC3", "#8C8C8C",
]


# ── helpers ──────────────────────────────────────────────────────────────────

def config_name_from_path(path: str) -> str:
    """
    Extract configuration name by stripping a trailing _run<N> (and extension).
    e.g. 'results_no-scaling_run1_stats.csv' → 'no-scaling'
    Handles arbitrary prefixes before the config name.
    """
    stem = Path(path).stem                          # e.g. results_no-scaling_run1_stats
    stem = re.sub(r'_stats$', '', stem)             # → results_no-scaling_run1
    stem = re.sub(r'_run\d+$', '', stem)            # → results_no-scaling
    # Drop a leading 'results_' prefix if present
    stem = re.sub(r'^results_', '', stem)           # → no-scaling
    return stem


def load_and_group(paths: list[str]) -> dict[str, pd.DataFrame]:
    """
    Load every CSV, group by configuration name, and return
    {config_name: averaged_dataframe}.
    """
    groups: dict[str, list[pd.DataFrame]] = defaultdict(list)

    for p in paths:
        df = pd.read_csv(p)
        df.columns = df.columns.str.strip()
        # Drop aggregated row
        df = df[~df["Name"].isin(SKIP_NAMES)].copy()
        # Create a readable label: "METHOD /path"
        df["label"] = df["Type"].str.strip() + " " + df["Name"].str.strip()
        cfg = config_name_from_path(p)
        groups[cfg].append(df)

    averaged: dict[str, pd.DataFrame] = {}
    for cfg, frames in groups.items():
        if len(frames) == 1:
            averaged[cfg] = frames[0].copy()
        else:
            # Concatenate and average numeric columns; keep label/Name/Type from first
            combined = pd.concat(frames)
            num_cols = combined.select_dtypes(include="number").columns.tolist()
            mean_df = (
                combined.groupby("label", sort=False)[num_cols]
                .mean()
                .reset_index()
            )
            averaged[cfg] = mean_df

    return averaged


def ms_formatter(x, _):
    """Format y-axis ticks as integer ms with comma separator."""
    return f"{int(x):,}"


# ── plotting ─────────────────────────────────────────────────────────────────

def plot_grouped_bars(configs: dict[str, pd.DataFrame], out_dir: Path):
    """
    One figure per metric.  Within each figure, one subplot per request type.
    X-axis = configurations, Y-axis = latency in ms.
    """
    # Collect all unique request labels in order of first appearance
    all_labels: list[str] = []
    for df in configs.values():
        for lbl in df["label"]:
            if lbl not in all_labels:
                all_labels.append(lbl)

    config_names = list(configs.keys())
    n_configs = len(config_names)
    colors = PALETTE[:n_configs]

    for metric_col, metric_label in METRICS.items():
        n_requests = len(all_labels)
        fig, axes = plt.subplots(
            1, n_requests,
            figsize=(4.5 * n_requests, 5),
            sharey=False,
        )
        if n_requests == 1:
            axes = [axes]

        fig.suptitle(f"{metric_label} — by Configuration", fontsize=14, fontweight="bold", y=1.02)

        bar_width = 0.65 / n_configs
        x = np.arange(n_configs)

        for ax, req_label in zip(axes, all_labels):
            values = []
            for cfg in config_names:
                df = configs[cfg]
                row = df[df["label"] == req_label]
                val = float(row[metric_col].iloc[0]) if not row.empty and metric_col in df.columns else 0.0
                values.append(val)

            bars = ax.bar(x, values, color=colors, width=0.6, edgecolor="white", linewidth=0.8)

            # Value labels on top of each bar
            for bar, val in zip(bars, values):
                if val > 0:
                    ax.text(
                        bar.get_x() + bar.get_width() / 2,
                        bar.get_height() * 1.02,
                        f"{val/1000:.1f}s" if val >= 1000 else f"{int(val)}ms",
                        ha="center", va="bottom", fontsize=7.5, rotation=0,
                    )

            ax.set_title(req_label, fontsize=9, fontweight="bold", pad=6)
            ax.set_xticks(x)
            ax.set_xticklabels(config_names, rotation=35, ha="right", fontsize=8)
            ax.yaxis.set_major_formatter(mticker.FuncFormatter(ms_formatter))
            ax.set_ylabel("Response time (ms)" if ax == axes[0] else "", fontsize=8)
            ax.grid(axis="y", linestyle="--", alpha=0.4)
            ax.spines[["top", "right"]].set_visible(False)

        fig.tight_layout()
        safe_metric = re.sub(r'[^\w]', '_', metric_label)
        out_path = out_dir / f"comparison_{safe_metric}.png"
        fig.savefig(out_path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  Saved → {out_path}")


def plot_metric_grid(configs: dict[str, pd.DataFrame], out_dir: Path):
    """
    Summary grid: rows = metrics, cols = request types.
    Each cell is a grouped bar chart across configurations.
    Useful for a single at-a-glance overview.
    """
    all_labels: list[str] = []
    for df in configs.values():
        for lbl in df["label"]:
            if lbl not in all_labels:
                all_labels.append(lbl)

    config_names = list(configs.keys())
    colors = PALETTE[:len(config_names)]
    metric_items = list(METRICS.items())

    n_rows = len(metric_items)
    n_cols = len(all_labels)
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(4.5 * n_cols, 3.5 * n_rows), sharey=False)

    if n_rows == 1:
        axes = [axes]
    if n_cols == 1:
        axes = [[ax] for ax in axes]

    fig.suptitle("Response-time Comparison — All Metrics × Request Types", fontsize=14, fontweight="bold", y=1.01)

    x = np.arange(len(config_names))

    for r, (metric_col, metric_label) in enumerate(metric_items):
        for c, req_label in enumerate(all_labels):
            ax = axes[r][c]
            values = []
            for cfg in config_names:
                df = configs[cfg]
                row = df[df["label"] == req_label]
                val = float(row[metric_col].iloc[0]) if not row.empty and metric_col in df.columns else 0.0
                values.append(val)

            ax.bar(x, values, color=colors, width=0.6, edgecolor="white", linewidth=0.8)

            if r == 0:
                ax.set_title(req_label, fontsize=8.5, fontweight="bold", pad=5)
            if c == 0:
                ax.set_ylabel(metric_label, fontsize=8.5)

            ax.set_xticks(x)
            ax.set_xticklabels(config_names, rotation=40, ha="right", fontsize=7)
            ax.yaxis.set_major_formatter(mticker.FuncFormatter(ms_formatter))
            ax.grid(axis="y", linestyle="--", alpha=0.35)
            ax.spines[["top", "right"]].set_visible(False)

    # Shared legend at the bottom
    from matplotlib.patches import Patch
    legend_handles = [Patch(facecolor=colors[i], label=name) for i, name in enumerate(config_names)]
    fig.legend(handles=legend_handles, loc="lower center", ncol=len(config_names),
               fontsize=9, bbox_to_anchor=(0.5, -0.03), frameon=False)

    fig.tight_layout()
    out_path = out_dir / "comparison_summary_grid.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved → {out_path}")


def plot_line_profiles(configs: dict[str, pd.DataFrame], out_dir: Path):
    """
    One subplot per request type.  X-axis = percentile level (Avg, p50, p95, p99).
    One line per configuration.  Good for seeing how latency distribution differs.
    """
    all_labels: list[str] = []
    for df in configs.values():
        for lbl in df["label"]:
            if lbl not in all_labels:
                all_labels.append(lbl)

    config_names = list(configs.keys())
    colors = PALETTE[:len(config_names)]
    x_labels = list(METRICS.values())
    x_pos = np.arange(len(x_labels))

    n = len(all_labels)
    fig, axes = plt.subplots(1, n, figsize=(4.5 * n, 4.5), sharey=False)
    if n == 1:
        axes = [axes]

    fig.suptitle("Latency Profile (Avg → p99) by Configuration", fontsize=13, fontweight="bold", y=1.02)

    for ax, req_label in zip(axes, all_labels):
        for i, (cfg, color) in enumerate(zip(config_names, colors)):
            df = configs[cfg]
            row = df[df["label"] == req_label]
            if row.empty:
                continue
            ys = [float(row[col].iloc[0]) if col in df.columns else 0.0 for col in METRICS]
            ax.plot(x_pos, ys, marker="o", color=color, label=cfg, linewidth=2, markersize=6)

        ax.set_title(req_label, fontsize=9, fontweight="bold")
        ax.set_xticks(x_pos)
        ax.set_xticklabels(x_labels, fontsize=8)
        ax.yaxis.set_major_formatter(mticker.FuncFormatter(ms_formatter))
        ax.set_ylabel("Response time (ms)" if ax == axes[0] else "", fontsize=8)
        ax.grid(linestyle="--", alpha=0.4)
        ax.spines[["top", "right"]].set_visible(False)

    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=len(config_names),
               fontsize=9, bbox_to_anchor=(0.5, -0.06), frameon=False)
    fig.tight_layout()

    out_path = out_dir / "comparison_line_profiles.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved → {out_path}")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: python plot_configs.py <glob-or-files>")
        print("  e.g. python plot_configs.py results_*.csv")
        sys.exit(1)

    # Accept both explicit file lists and glob patterns
    paths: list[str] = []
    for arg in sys.argv[1:]:
        expanded = glob.glob(arg)
        paths.extend(expanded if expanded else [arg])

    if not paths:
        print("No CSV files found.")
        sys.exit(1)

    print(f"Loading {len(paths)} file(s)...")
    configs = load_and_group(paths)
    print(f"Configurations detected: {', '.join(configs.keys())}")

    out_dir = Path(".")
    print("\nGenerating plots...")

    # 1. One figure per metric (grouped bar, configs on x-axis)
    plot_grouped_bars(configs, out_dir)

    # 2. Full summary grid (metrics × request types)
    plot_metric_grid(configs, out_dir)

    # 3. Line profiles (percentile curves per request type)
    plot_line_profiles(configs, out_dir)

    print("\nDone.")


if __name__ == "__main__":
    main()
