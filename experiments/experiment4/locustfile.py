
import itertools
import threading
import uuid
from locust import HttpUser, task, events
from locust.exception import StopUser

# ---------------------------------------------------------------------------
# Seat cycling — each event gets its own independent cycle
# ---------------------------------------------------------------------------
_seat_cycles = {
    "evt-001": itertools.cycle(range(1, 1001)),
    "evt-002": itertools.cycle(range(1, 501)),
    "evt-003": itertools.cycle(range(1, 201)),
    "evt-004": itertools.cycle(range(1, 101)),
    "evt-005": itertools.cycle(range(1, 2001)),
}
_seat_locks = {k: threading.Lock() for k in _seat_cycles}

def next_seat(event_id):
    with _seat_locks[event_id]:
        return next(_seat_cycles[event_id])

# ---------------------------------------------------------------------------
# Per-event 409 counters — tracks contention without polluting Locust stats
# ---------------------------------------------------------------------------
_contention = {k: 0 for k in _seat_cycles}
_contention_lock = threading.Lock()

def record_contention(event_id):
    with _contention_lock:
        _contention[event_id] = _contention.get(event_id, 0) + 1

# ---------------------------------------------------------------------------
# Config — read from Locust CLI args
# ---------------------------------------------------------------------------
_cfg = {"db_backend": "mysql"}

@events.init_command_line_parser.add_listener
def add_args(parser, **kwargs):
    parser.add_argument(
        "--db-backend", default="mysql",
        choices=["mysql", "dynamodb"],
        help="Storage backend to use"
    )

@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    _cfg["db_backend"] = environment.parsed_options.db_backend

@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    print("\n[Experiment 4] Contention (409) counts per event:")
    for event_id, count in sorted(_contention.items()):
        print(f"  {event_id}: {count} contention events")
    print("[Experiment 4] These reflect lock contention, not test failures.")

# ---------------------------------------------------------------------------
# Shared booking helper
# ---------------------------------------------------------------------------
def book_seat(client, event_id):
    seat_num = next_seat(event_id)
    seat_id  = f"{event_id}-seat-{seat_num:04d}"
    customer_id = abs(hash(f"{event_id}-{seat_num}-{uuid.uuid4()}")) % 100000

    with client.post(
        "/booking/api/v1/bookings",
        json={
            "event_id":    event_id,
            "seat_id":     seat_id,
            "customer_id": customer_id,
            "db_backend":  _cfg["db_backend"],
        },
        catch_response=True,
        name=f"/bookings [{event_id}]",
    ) as resp:
        if resp.status_code == 201:
            resp.success()
        elif resp.status_code == 409:
            resp.success()  # contention — expected, tracked separately
            record_contention(event_id)
        else:
            resp.failure(f"HTTP {resp.status_code}: {resp.text[:120]}")

# ---------------------------------------------------------------------------
# User classes — one per event, weighted by demand
# ---------------------------------------------------------------------------

class TaylorSwiftUser(HttpUser):
    """evt-001 — highest demand, ~40% of users"""
    weight = 40

    @task
    def book(self):
        book_seat(self.client, "evt-001")
        raise StopUser()


class DrakeUser(HttpUser):
    """evt-005 — moderate demand, ~25% of users"""
    weight = 25

    @task
    def book(self):
        book_seat(self.client, "evt-005")
        raise StopUser()


class ColdplayUser(HttpUser):
    """evt-002 — ~15% of users"""
    weight = 15

    @task
    def book(self):
        book_seat(self.client, "evt-002")
        raise StopUser()


class TheWeekndUser(HttpUser):
    """evt-003 — ~12% of users"""
    weight = 12

    @task
    def book(self):
        book_seat(self.client, "evt-003")
        raise StopUser()


class BillieEilishUser(HttpUser):
    """evt-004 — lowest demand, ~8% of users — key isolation test"""
    weight = 8

    @task
    def book(self):
        book_seat(self.client, "evt-004")
        raise StopUser()