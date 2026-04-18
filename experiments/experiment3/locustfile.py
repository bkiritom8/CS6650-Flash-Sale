import itertools
import time

from locust import HttpUser, LoadTestShape, between, task, events
POLL_INTERVAL    = 2        # seconds between status polls
MAX_WAIT_SECONDS = 120      # 2-minute admission timeout
MAX_SEATS        = 1000      # TODO: set to your actual seat range
EVENT_ID         = "evt-001"    # TODO: set to your event ID


class TicketDropLoadShape(LoadTestShape):
    surge_time = 60  # seconds to reach target user count
    surge_users = 3000  # target user count to surge to
    sustain_time = 180  # seconds to sustain target user count before stopping
    sustain_users = 3000  # user count to sustain during the sustain phase
    drop_time = 30  # seconds to drop back to 0 users
    
    def __init__(self):
        super().__init__()
        self.phases = {
            "Surge Phase": {"end_time": self.surge_time,"users": self.surge_users, "spawn_rate": self.surge_users / self.surge_time},
            "Sustain Phase": {"end_time": self.surge_time + self.sustain_time,"users": self.sustain_users, "spawn_rate": (self.sustain_users - self.surge_users) / self.sustain_time},
            "Drop Phase": {"end_time": self.surge_time + self.sustain_time + self.drop_time,"users": 0, "spawn_rate": (0 - self.sustain_users) / self.drop_time}
        }
    
    def tick(self):
        run_time = self.get_run_time()

        for phase_name, phase in self.phases.items():
            if run_time < phase["end_time"]:
                return (phase["users"], phase["spawn_rate"])

        return None  # Stop the test after all phases are complete


seat_cycle = itertools.cycle(range(1, MAX_SEATS + 1))


def make_booking(client, event_id, seat_number, customer_id):
    """
    POST to the booking endpoint.
    Manually marks non-201/409 responses as failures, since Locust only
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
        elif resp.status_code == 409:
            resp.success()  # contention — expected, don't mark as failure
        else:
            resp.failure(f"Unexpected status code: {resp.status_code}. Failed to place order: {resp.text}")


class QueuedBookingUser(HttpUser):
    wait_time = between(0.5, 1)

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
                # events.request.fire(
                #     request_type="QUEUE",
                #     name="queue_admission",
                #     response_time=elapsed * 1000,   # ms
                #     response_length=0,
                #     exception=Exception("Admission timeout after 2 minutes"),
                # )
                admitted = False
                break  # skip booking — never admitted

            # Poll status endpoint
            with self.client.get(
                f"/queue/api/v1/queue/status/{queue_id}",
                name="/queue/api/v1/queue/status/[queue_id]",
                catch_response=True
            ) as status_resp:
                status = status_resp.json().get("status")
                status_resp.success()
                if status == "admitted":
                    admitted = True
                    break

            time.sleep(POLL_INTERVAL)

        events.request.fire(
            request_type="QUEUE",
            name="queue_admission",
            response_time= (time.time() - start_time) * 1000,   # ms
            response_length=0,
            exception=None if admitted else Exception("Admission timeout after 2 minutes"),
        )

        # --- Phase 3: Book (only if admitted) ---
        if admitted:
            make_booking(self.client, EVENT_ID, seat_number, customer_id)