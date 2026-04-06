import sys
import csv

# Map Locust endpoint names to event IDs
EVENT_NAMES = {
    "/bookings [evt-001]": "evt-001",
    "/bookings [evt-002]": "evt-002",
    "/bookings [evt-003]": "evt-003",
    "/bookings [evt-004]": "evt-004",
    "/bookings [evt-005]": "evt-005",
}

def main():
    if len(sys.argv) < 2:
        print("- - - - - - -")
        return

    path = sys.argv[1]
    found = False
    try:
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                name = row.get("Name", "").strip()
                if name == "Aggregated" or name not in EVENT_NAMES:
                    continue
                event_id = EVENT_NAMES[name]
                avg  = round(float(row.get("Average Response Time", 0) or 0))
                p50  = row.get("50%",  "-") or "-"
                p95  = row.get("95%",  "-") or "-"
                p99  = row.get("99%",  "-") or "-"
                reqs = row.get("Request Count",  "0") or "0"
                fails= row.get("Failure Count",  "0") or "0"
                print(event_id, avg, p50, p95, p99, reqs, fails)
                found = True
    except Exception:
        pass

    if not found:
        print("- - - - - - -")


if __name__ == "__main__":
    main()