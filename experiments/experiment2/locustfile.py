import time
import itertools
import uuid
from locust import HttpUser, task, between, events
from locust.exception import StopUser

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
POLL_INTERVAL    = 2        # seconds between status polls
MAX_WAIT_SECONDS = 120      # 2-minute admission timeout
MAX_SEATS        = 1000      # TODO: set to your actual seat range
EVENT_ID         = "evt-001"    # TODO: set to your event ID

# Shared across all user instances — each next() call advances globally
seat_cycle = itertools.cycle(range(1, MAX_SEATS + 1))

# ---------------------------------------------------------------------------
# Shared helper
# ---------------------------------------------------------------------------
def make_booking(client, event_id, seat_number, customer_id):
    """
    POST to the booking endpoint.
    Manually marks non-201 responses as failures, since Locust only
    auto-fails on exceptions/network errors by default.
    """
    payload = {
        "event_id":    event_id,
        "seat_id": "{}-seat-{}".format(event_id, seat_number),
        "customer_id": customer_id,
    }
    with client.post(
        "/booking/api/v1/bookings",
        json=payload,
        catch_response=True
    ) as resp:
        if resp.status_code == 201:
            resp.success()
        else:
            resp.failure(f"Unexpected status code: {resp.status_code}. Failed to place order: {resp.text}")


# ---------------------------------------------------------------------------
# Scenario 1 — Direct (unbuffered)
# ---------------------------------------------------------------------------
class DirectBookingUser(HttpUser):
    #wait_time = between(1, 2)  # TODO: tune to match Scenario 2's effective rate

    @task
    def book_direct(self):
        seat_number = next(seat_cycle)
        #customer_id = str(uuid.uuid4())
        customer_id = 100 + seat_number
        make_booking(self.client, EVENT_ID, seat_number, customer_id)
        raise StopUser()  # one booking per user instance, then stop


# ---------------------------------------------------------------------------
# Scenario 2 — Queued (buffered)
# ---------------------------------------------------------------------------
class QueuedBookingUser(HttpUser):
    #wait_time = between(1, 2)  # TODO: tune to match Scenario 1

    @task
    def book_via_queue(self):
        seat_number = next(seat_cycle)
        #customer_id = str(uuid.uuid4())
        customer_id = 100 + seat_number 

        # --- Phase 1: Enqueue ---
        with self.client.post(
            "/queue/api/v1/queue/join",
            json={"event_id": EVENT_ID, "customer_id": customer_id},
            catch_response=True
        ) as enqueue_resp:
            if enqueue_resp.status_code != 201:
                enqueue_resp.failure(f"Enqueue failed: {enqueue_resp.status_code}")
                return
            queue_id = enqueue_resp.json().get("queue_id")

        # --- Phase 2: Poll for admission ---
        start_time = time.time()
        admitted = False

        while True:
            elapsed = time.time() - start_time

            # Timeout — fire as its own named event so it's isolated in stats
            if elapsed > MAX_WAIT_SECONDS:
                events.request.fire(
                    request_type="QUEUE",
                    name="queue_admission",
                    response_time=elapsed * 1000,   # ms
                    response_length=0,
                    exception=Exception("Admission timeout after 2 minutes"),
                )
                return  # skip booking — never admitted

            # Poll status endpoint
            status_resp = self.client.get(
                f"/queue/api/v1/queue/status/{queue_id}"
            )
            status = status_resp.json().get("status")

            if status == "admitted":
                admitted = True
                break

            time.sleep(POLL_INTERVAL)

        # --- Phase 3: Book (only if admitted) ---
        if admitted:
            make_booking(self.client, EVENT_ID, seat_number, customer_id)
        raise StopUser()  # one booking per user instance, then stop