import itertools
import threading
import time
from locust import HttpUser, task, events
from locust.exception import StopUser

# ---------------------------------------------------------------------------
# Config — overridable via CLI args
# ---------------------------------------------------------------------------
POLL_INTERVAL    = 2      # seconds between queue status polls
MAX_WAIT_SECONDS = 120    # 2-minute admission timeout
MAX_SEATS        = 1000   # seat range for evt-001
EVENT_ID         = "evt-001"

_cfg = {
    "fairness_mode": "allow_multiple",
    "greedy_joins":  3,
}

@events.init_command_line_parser.add_listener
def add_args(parser, **kwargs):
    parser.add_argument(
        "--fairness-mode",
        choices=["collapse", "allow_multiple"],
        default="allow_multiple",
        help="Queue fairness policy under test",
    )
    parser.add_argument(
        "--greedy-joins",
        type=int,
        default=3,
        help="How many queue slots a GreedyUser tries to claim (simulates N tabs)",
    )

@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    opts = environment.parsed_options
    _cfg["fairness_mode"] = opts.fairness_mode
    _cfg["greedy_joins"]  = opts.greedy_joins

# ---------------------------------------------------------------------------
# Per-cohort stats — printed at test end for fairness analysis
# ---------------------------------------------------------------------------
_stats = {
    "greedy_booked":    0,
    "greedy_timeout":   0,
    "greedy_collapsed": 0,   # times server deduped N joins → 1 slot
    "greedy_total_joins": 0, # total queue join attempts by greedy users
    "fair_booked":      0,
    "fair_timeout":     0,
}
_stats_lock = threading.Lock()

@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    mode = _cfg["fairness_mode"]
    n    = _cfg["greedy_joins"]
    s    = _stats

    print(f"\n[Experiment 5] fairness_mode={mode}  greedy_joins_per_user={n}")
    print( "  ─────────────────────────────────────────────────────")
    print(f"  Greedy users  — booked: {s['greedy_booked']:>5}  timeout: {s['greedy_timeout']:>5}")
    print(f"  Fair users    — booked: {s['fair_booked']:>5}  timeout: {s['fair_timeout']:>5}")
    print( "  ─────────────────────────────────────────────────────")
    print(f"  Total greedy join attempts : {s['greedy_total_joins']}")
    print(f"  Collapsed (deduped by IP)  : {s['greedy_collapsed']}")

    g_total = s["greedy_booked"] + s["greedy_timeout"]
    f_total = s["fair_booked"]   + s["fair_timeout"]
    if g_total > 0:
        print(f"  Greedy success rate: {s['greedy_booked'] / g_total * 100:.1f}%")
    if f_total > 0:
        print(f"  Fair   success rate: {s['fair_booked']   / f_total * 100:.1f}%")
    if g_total > 0 and f_total > 0:
        g_rate = s["greedy_booked"] / g_total
        f_rate = s["fair_booked"]   / f_total
        ratio  = (g_rate / f_rate) if f_rate > 0 else float("inf")
        print(f"  Fairness ratio (greedy/fair success rate): {ratio:.2f}x")
        print( "  (1.0 = fair; >1.0 = greedy users have an advantage)")

# ---------------------------------------------------------------------------
# Thread-safe seat and user-ID counters
# ---------------------------------------------------------------------------
_seat_cycle = itertools.cycle(range(1, MAX_SEATS + 1))
_seat_lock  = threading.Lock()

def _next_seat():
    with _seat_lock:
        return next(_seat_cycle)

_user_counter      = itertools.count(1)
_user_counter_lock = threading.Lock()

def _next_user_id():
    with _user_counter_lock:
        return next(_user_counter)

def _synthetic_ip(user_id: int) -> str:
    """
    Fabricate a unique source IP per user to simulate requests from
    different machines.  All join requests from a single GreedyUser
    instance share the same IP so the server can recognise and collapse
    them in 'collapse' mode.

    Note: behind an AWS ALB the real client IP is forwarded in
    X-Forwarded-For.  This header is respected if Gin's trusted-proxy
    list includes the ALB.  In direct/local runs it works as-is.
    """
    octet2 = (user_id >> 8) & 0xFF
    octet3 = user_id & 0xFF
    return f"10.{octet2}.{octet3}.1"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
def _join_queue(client, customer_id: int, ip: str) -> str | None:
    """
    POST /queue/join with a synthetic source IP.
    Returns queue_id on success, None on failure.
    """
    with client.post(
        "/queue/api/v1/queue/join",
        json={"event_id": EVENT_ID, "customer_id": customer_id},
        headers={"X-Forwarded-For": ip},
        catch_response=True,
        name="queue/join",
    ) as resp:
        if resp.status_code == 201:
            resp.success()
            return resp.json().get("queue_id")
        resp.failure(f"Join failed: {resp.status_code} {resp.text[:80]}")
        return None


def _poll_until_admitted(client, queue_id: str) -> bool:
    """
    Poll /queue/status until admitted or timeout.
    Returns True if admitted, False on timeout.
    Fires a named QUEUE event on timeout so it appears in Locust stats.
    """
    start = time.time()
    while True:
        elapsed = time.time() - start
        if elapsed > MAX_WAIT_SECONDS:
            events.request.fire(
                request_type="QUEUE",
                name="queue_admission_timeout",
                response_time=elapsed * 1000,
                response_length=0,
                exception=Exception(f"Admission timeout after {MAX_WAIT_SECONDS}s"),
            )
            return False

        resp   = client.get(
            f"/queue/api/v1/queue/status/{queue_id}",
            name="queue/status",
        )
        status = resp.json().get("status", "")

        if status == "admitted":
            return True

        time.sleep(POLL_INTERVAL)


def _make_booking(client, seat_num: int, customer_id: int) -> bool:
    """
    POST /booking/api/v1/bookings.
    Returns True on 201, False otherwise.

    lock_mode=optimistic: avoids MySQL InnoDB gap-lock deadlocks that occur
    under LevelSerializable isolation when seat_versions rows don't yet exist.
    Experiment 5 measures queue fairness, not locking strategy, so optimistic
    CAS retries are the correct choice for a clean booking success signal.
    """
    with client.post(
        "/booking/api/v1/bookings",
        json={
            "event_id":    EVENT_ID,
            "seat_id":     f"{EVENT_ID}-seat-{seat_num:04d}",
            "customer_id": customer_id,
            "lock_mode":   "optimistic",
        },
        catch_response=True,
        name="booking/book",
    ) as resp:
        if resp.status_code == 201:
            resp.success()
            return True
        resp.failure(f"Booking failed: {resp.status_code} {resp.text[:80]}")
        return False


# ---------------------------------------------------------------------------
# Scenario A — Greedy user (multiple tabs / devices)
# ---------------------------------------------------------------------------
class GreedyUser(HttpUser):
    """
    Simulates a user opening N browser tabs (or using N devices), each
    independently joining the queue.

    allow_multiple mode: each join creates a new queue slot → the user
        holds N positions and is admitted N times sooner than a fair user.

    collapse mode: the server recognises the shared IP and returns the
        same queue slot for all N joins → the user has no advantage.

    The user polls only the first (or only) unique queue_id and books
    exactly once.  Any phantom positions (N-1 extras in allow_multiple)
    remain in the queue and block real fair users behind them.
    """
    weight = 40

    @task
    def book_greedy(self):
        user_id    = _next_user_id()
        session_ip = _synthetic_ip(user_id)
        n          = _cfg["greedy_joins"]
        seat_num   = _next_seat()
        customer_id = user_id % 100000

        # --- Phase 1: attempt N queue joins with the same session IP ---
        queue_ids = []
        for i in range(n):
            # Ensure join_customer_id is never 0 — the API rejects CustomerID=0
            # because Go's binding:"required" treats zero-value int as missing.
            join_customer_id = (customer_id * 1000 + i) % 100000 or customer_id
            qid = _join_queue(self.client, join_customer_id, session_ip)
            if qid:
                queue_ids.append(qid)

        with _stats_lock:
            _stats["greedy_total_joins"] += len(queue_ids)

        if not queue_ids:
            raise StopUser()

        # Detect server-side deduplication (collapse mode returns same queue_id)
        unique_ids  = list(dict.fromkeys(queue_ids))  # preserve order, drop dupes
        collapsed   = len(unique_ids) < len(queue_ids)

        if collapsed:
            with _stats_lock:
                _stats["greedy_collapsed"] += 1

        # --- Phase 2: poll first (or only) unique queue position ---
        admitted = _poll_until_admitted(self.client, unique_ids[0])

        # --- Phase 3: book once ---
        if admitted:
            booked = _make_booking(self.client, seat_num, customer_id)
            with _stats_lock:
                if booked:
                    _stats["greedy_booked"] += 1
        else:
            with _stats_lock:
                _stats["greedy_timeout"] += 1

        raise StopUser()


# ---------------------------------------------------------------------------
# Scenario B — Fair user (single join, single position)
# ---------------------------------------------------------------------------
class FairUser(HttpUser):
    """
    Simulates a well-behaved user who joins the queue exactly once.
    Each user gets a unique synthetic IP so they are never collapsed by
    the server.  Their success rate relative to GreedyUser's measures
    how much the multi-join behaviour harms honest participants.
    """
    weight = 60

    @task
    def book_fair(self):
        user_id     = _next_user_id()
        # Offset into a different /8 subnet to avoid collision with greedy IPs
        session_ip  = _synthetic_ip(user_id + 50000)
        seat_num    = _next_seat()
        customer_id = user_id % 100000

        # --- Phase 1: single queue join ---
        qid = _join_queue(self.client, customer_id, session_ip)
        if not qid:
            raise StopUser()

        # --- Phase 2: poll for admission ---
        admitted = _poll_until_admitted(self.client, qid)

        # --- Phase 3: book ---
        if admitted:
            booked = _make_booking(self.client, seat_num, customer_id)
            with _stats_lock:
                if booked:
                    _stats["fair_booked"] += 1
        else:
            with _stats_lock:
                _stats["fair_timeout"] += 1

        raise StopUser()
