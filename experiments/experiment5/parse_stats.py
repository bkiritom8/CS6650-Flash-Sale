"""
parse_stats.py — reads a Locust stats CSV and prints one line per
non-Aggregated endpoint row:

    name avg p50 p95 p99 requests failures

Called by exp5-locust-test.sh to avoid heredoc issues on Windows Git Bash.

Usage:
    python parse_stats.py <stats_csv_path>
Output (one line per endpoint):
    queue/join  312 280 590 710 1500 0
    queue/status 45  40  90 120 8200 0
    booking/book 220 200 410 520  480 12
    or a single "- - - - - - -" if the file is missing.
"""
import sys
import csv


def main():
    if len(sys.argv) < 2:
        print("- - - - - - -")
        return

    path = sys.argv[1]
    try:
        with open(path, newline="", encoding="utf-8") as f:
            found = False
            for row in csv.DictReader(f):
                name = row.get("Name", "").strip()
                if name == "Aggregated":
                    continue
                avg  = round(float(row.get("Average Response Time", 0) or 0))
                p50  = row.get("50%",  "-") or "-"
                p95  = row.get("95%",  "-") or "-"
                p99  = row.get("99%",  "-") or "-"
                reqs = row.get("Request Count", "0") or "0"
                fails= row.get("Failure Count", "0") or "0"
                print(name, avg, p50, p95, p99, reqs, fails)
                found = True
        if not found:
            print("- - - - - - -")
    except Exception:
        print("- - - - - - -")


if __name__ == "__main__":
    main()
