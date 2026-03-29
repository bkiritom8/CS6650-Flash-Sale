"""
parse_stats.py — reads a Locust stats CSV and prints:
  avg p50 p95 p99 request_count failure_count
for the first non-Aggregated row.

Called by exp2-locust-test.sh to avoid heredoc issues on Windows Git Bash.

Usage:
    python parse_stats.py <stats_csv_path>
Output:
    avg p50 p95 p99 requests failures
    e.g. "805 660 1800 2400 920 243"
    or   "- - - - - -"  if file not found
"""
import sys
import csv


def main():
    if len(sys.argv) < 2:
        print("- - - - - -")
        return

    path = sys.argv[1]
    try:
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                # Skip the Aggregated summary row, use first real endpoint row
                if row.get("Name", "").strip() == "Aggregated":
                    continue
                avg  = round(float(row.get("Average Response Time", 0) or 0))
                p50  = row.get("50%",  "-") or "-"
                p95  = row.get("95%",  "-") or "-"
                p99  = row.get("99%",  "-") or "-"
                reqs = row.get("Request Count",  "0") or "0"
                fails= row.get("Failure Count",  "0") or "0"
                print(avg, p50, p95, p99, reqs, fails)
                return
    except Exception:
        pass

    print("- - - - - -")


if __name__ == "__main__":
    main()