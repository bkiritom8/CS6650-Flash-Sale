"""
parse_stats.py — reads a Locust stats CSV and prints avg p50 p95 p99
for the /seat/book endpoint on a single line.

Called by exp1-locust-test.sh — replaces the heredoc approach which
is unreliable on Windows Git Bash.

Usage:
    python parse_stats.py <stats_csv_path>
Output:
    avg p50 p95 p99   (space separated, e.g. "453 500 600 610")
    - - - -           (if file not found or row not present)
"""
import sys
import csv

def main():
    if len(sys.argv) < 2:
        print("- - - -")
        return

    path = sys.argv[1]
    try:
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if "/seat/book" in row.get("Name", ""):
                    avg = round(float(row.get("Average Response Time", 0) or 0))
                    p50 = row.get("50%", "-") or "-"
                    p95 = row.get("95%", "-") or "-"
                    p99 = row.get("99%", "-") or "-"
                    print(avg, p50, p95, p99)
                    return
    except Exception:
        pass

    print("- - - -")

if __name__ == "__main__":
    main()