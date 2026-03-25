"""
Experiment 1 — Locust load test
---------------------------------
Each virtual user books a single seat exactly once (in on_start), then idles.
The test script (scripts/test.sh) manages the seat lifecycle: init → locust → results → cleanup.

Usage (via scripts/test.sh):
    locust -f locustfile.py \\
        --host http://<ALB>/experiment1 \\
        --headless \\
        --users 1000 --spawn-rate 1000 \\
        --run-time 30s \\
        --lock-mode none \\
        --db-backend mysql \\
        --event-id exp1-abcd1234 \\
        --seat-id seat-last
"""
import uuid
import threading
from locust import HttpUser, task, constant, events

_init_done = threading.Event()
_cfg: dict = {}


@events.init_command_line_parser.add_listener
def add_args(parser, **kwargs):
    parser.add_argument("--lock-mode",   default="none",      choices=["none", "optimistic", "pessimistic"])
    parser.add_argument("--db-backend",  default="mysql",     choices=["mysql", "dynamodb"])
    parser.add_argument("--max-retries", default=3,           type=int)
    parser.add_argument("--event-id",    default="",          help="Pre-initialised event_id from test.sh")
    parser.add_argument("--seat-id",     default="seat-last", help="Seat to contest")


@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    opts = environment.parsed_options
    _cfg.update(
        lock_mode=opts.lock_mode,
        db_backend=opts.db_backend,
        max_retries=opts.max_retries,
        event_id=opts.event_id or f"exp1-{uuid.uuid4().hex[:8]}",
        seat_id=opts.seat_id,
    )
    _init_done.set()


class BookingUser(HttpUser):
    """
    Each user attempts one booking on spawn (on_start), then idles.
    wait_time=constant(9999) ensures the @task placeholder almost never fires.
    """
    wait_time = constant(9999)

    def on_start(self):
        _init_done.wait(timeout=30)
        with self.client.post(
            "/api/v1/seat/book",
            json={
                "event_id":    _cfg["event_id"],
                "seat_id":     _cfg["seat_id"],
                "booking_id":  str(uuid.uuid4()),
                "lock_mode":   _cfg["lock_mode"],
                "db_backend":  _cfg["db_backend"],
                "max_retries": _cfg["max_retries"],
            },
            catch_response=True,
            name="/seat/book",
        ) as resp:
            if resp.status_code in (200, 409):
                # Both are valid outcomes:
                # 200 = this user got the seat
                # 409 = seat taken (expected for all but one user in locking modes)
                resp.success()
            else:
                resp.failure(f"HTTP {resp.status_code}: {resp.text[:120]}")

    @task
    def noop(self):
        pass
