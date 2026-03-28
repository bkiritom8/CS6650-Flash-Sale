"""
Experiment 1 — Locking Strategy Load Test
------------------------------------------
Each virtual user joins a "waiting room" on spawn and waits until ALL users
are spawned before rushing the booking endpoint simultaneously. This maximises
write contention — simulating a real flash sale.

Lock mode and DB backend are passed per-request so all three strategies
can be tested back-to-back without redeploying.

Targets the main booking-service directly (no separate experiment service).

Usage:
    locust -f experiment1.py \
        --host http://<ALB> \
        --headless \
        --users 1000 --spawn-rate 1000 \
        --run-time 60s \
        --lock-mode none \
        --db-backend mysql \
        --event-id exp1-abcd1234 \
        --seat-id seat-last
"""
import uuid
import threading
from locust import HttpUser, task, constant, events

_init_done      = threading.Event()   # set when test_start config is ready
_spawn_complete = threading.Event()   # set when all users have been spawned
_cfg: dict = {}


@events.init_command_line_parser.add_listener
def add_args(parser, **kwargs):
    parser.add_argument("--lock-mode",   default="none",      choices=["none", "optimistic", "pessimistic"])
    parser.add_argument("--db-backend",  default="mysql",     choices=["mysql", "dynamodb"])
    parser.add_argument("--max-retries", default=3,           type=int)
    parser.add_argument("--event-id",    default="",          help="event_id from the test script")
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


@events.spawning_complete.add_listener
def on_spawning_complete(user_count, **kwargs):
    """Open the waiting-room gate: all users rush simultaneously."""
    _spawn_complete.set()


class BookingUser(HttpUser):
    """
    Waiting-room pattern:
      1. User spawns and blocks at _spawn_complete.wait()
      2. Once ALL users are spawned, the gate opens and everyone attempts
         to book the same seat at the same instant — maximum contention.

    Expected per lock mode:
      none        — nearly all 200s; oversell_count >> 0 (race condition)
      optimistic  — one 201, rest 409 after retries exhaust
      pessimistic — one 201, rest immediate 409
    """
    wait_time = constant(9999)

    def on_start(self):
        _init_done.wait(timeout=30)
        _spawn_complete.wait(timeout=300)

        with self.client.post(
            "/booking/api/v1/bookings",
            json={
                "event_id":    _cfg["event_id"],
                "seat_id":     _cfg["seat_id"],
                "customer_id": str(uuid.uuid4()),
                "lock_mode":   _cfg["lock_mode"],
                "db_backend":  _cfg["db_backend"],
                "max_retries": _cfg["max_retries"],
            },
            catch_response=True,
            name="/seat/book",
        ) as resp:
            if resp.status_code in (200, 201, 409):
                resp.success()
            else:
                resp.failure(f"HTTP {resp.status_code}: {resp.text[:120]}")

    @task
    def noop(self):
        pass
