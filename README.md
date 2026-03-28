# Concert Ticket Platform

## Prerequisites

- Go 1.21+
- Terraform 1.5+
- Docker Desktop (must be running)
- AWS CLI v2, configured with your student account credentials
- Python 3 + `locust` (`pip install locust`)
- `curl`, `jq`

---

## Repository Structure

```
CS6650-Flash-Sale/
├── src/
│   ├── inventory-service/     # Manages events and seats
│   ├── booking-service/       # Handles bookings + concurrency control
│   │                          # Supports per-request lock_mode and db_backend overrides
│   └── queue-service/         # Virtual waiting room
├── experiments/
│   └── experiment1/           # Exp 1: locking strategy benchmarks
│       ├── experiment1.py     # Locust load test (waiting-room pattern)
│       └── requirements.txt
├── terraform/
│   ├── main/                  # Root platform config — run all Terraform from here
│   └── modules/               # alb, autoscaling, dynamodb, ecr, ecs, logging, network, rds
├── results/                   # Saved benchmark CSV results
│   └── exp1_<timestamp>.csv
└── scripts/
    ├── deploy.sh              # Full platform deploy
    ├── cleanup.sh             # Tear down all platform resources
    ├── test-platform.sh       # Smoke test all platform endpoints
    ├── exp1-deploy.sh         # Deploy experiment1
    ├── exp1-cleanup.sh        # Tear down experiment1 only
    ├── exp1-test.sh           # Quick experiment1 correctness test
    └── exp1-locust-test.sh    # Full Locust benchmark (all backends × all lock modes)
```

---

## Environment Variables

| Variable | Service | Values | Default |
|---|---|---|---|
| `DB_BACKEND` | booking | `mysql` \| `dynamodb` | `mysql` |
| `LOCK_MODE` | booking | `none` \| `optimistic` \| `pessimistic` | `pessimistic` |
| `BOOKING_SERVICE_URL` | experiment1 | URL to booking service | required |
| `ADMISSION_RATE` | queue | integer (admissions/sec) | `10` |
| `FAIRNESS_MODE` | queue | `collapse` \| `allow_multiple` | `allow_multiple` |
| `AUTOSCALING_CPU_TARGET` | Terraform var | integer (%) | `70` |

> **Note:** `lock_mode` and `db_backend` can also be passed per-request in the booking service — experiment1 uses this to test all 6 combinations without redeploying.

---

## Deploying the Platform

### Step 1 — Configure AWS credentials

```bash
export AWS_REGION=us-east-1
aws sts get-caller-identity   # verify credentials work
```

### Step 2 — Deploy everything

```bash
bash scripts/deploy.sh
```

This will:
1. Run `go mod tidy` on all services
2. Run `terraform init` and `terraform apply`
3. Build all Docker images locally (`--platform linux/amd64`) and push to ECR
4. Provision: VPC, NAT, ALB, RDS MySQL, DynamoDB (5 tables), ECS (3 services), CloudWatch
5. Wait for all health checks to pass

**Expected time: 8–12 minutes** (RDS takes the longest)

### Step 3 — Verify

```bash
bash scripts/test-platform.sh
```

---

## Tearing Down

```bash
bash scripts/cleanup.sh
```

Type `yes` when prompted. Scales down ECS, clears ECR images, then runs `terraform destroy`.

---

## Experiment Guide

### Experiment 1 — Concurrency Control Under Flash Sale Load

**What it tests:** Three locking strategies (none / optimistic / pessimistic) against two storage backends (MySQL/RDS and DynamoDB), with all users simultaneously rushing the last available seat.

**Architecture:** Separate ECS Fargate service that drives the existing booking-service API — no duplicate DB code. The booking-service accepts `lock_mode` and `db_backend` per request so all 6 combinations can be tested in a single run.

#### Deploy

```bash
# Deploy main platform first, then:
bash scripts/exp1-deploy.sh
```

#### Run the full Locust benchmark

```bash
# All 6 combinations: mysql×3 + dynamodb×3
bash scripts/exp1-locust-test.sh

# Override concurrency
CONCURRENCY=1000 bash scripts/exp1-locust-test.sh

# Single backend only
BACKENDS="mysql" bash scripts/exp1-locust-test.sh
```

Results are saved to `results/exp1_<timestamp>.csv` after each run.

**Expected results (1000 users):**

| Backend | Lock Mode | Bookings | Oversells | Notes |
|---|---|---|---|---|
| MySQL | none | ~630 | ~630 | Baseline — race window causes oversells |
| MySQL | optimistic | 1 | 0 | CAS retry on version column |
| MySQL | pessimistic | 1 | 0 | `SELECT ... FOR UPDATE` |
| DynamoDB | none | ~1000 | ~999 | Baseline |
| DynamoDB | optimistic | 1 | 0 | Conditional UpdateItem on version |
| DynamoDB | pessimistic | 1 | 0 | Conditional write with in-progress fence |

> **Note on concurrency:** Keep `CONCURRENCY` at or below 5,000 — the Fargate task is 512 CPU / 1 GB RAM and will OOM above that.

#### Run a single experiment via API

```bash
ALB=$(cd terraform/main && terraform output -raw alb_dns_name)

curl -s -X POST http://$ALB/experiment1/api/v1/run \
  -H "Content-Type: application/json" \
  -d '{"lock_mode":"pessimistic","db_backend":"mysql","concurrency":1000}' | jq .
```

**Response fields:**

| Field | Description |
|---|---|
| `successful_bookings` | Bookings confirmed by the booking service |
| `failed_bookings` | Requests that got a conflict / retry-exhausted error |
| `oversell_count` | DB-verified double-bookings (should be 0 for optimistic/pessimistic) |
| `oversell_rate_pct` | `oversell_count / concurrency × 100` |
| `total_duration_ms` | Wall time from first goroutine start to last finish |
| `latency_ms.min/max/mean/p99` | Per-attempt latency across all goroutines |

#### Tear down experiment1

```bash
bash scripts/exp1-cleanup.sh
```

Scales ECS to 0, clears ECR images, then runs `terraform destroy`. Main platform is untouched.

#### CloudWatch logs

```bash
aws logs tail /ecs/concert-platform-experiment1 --follow --region us-east-1
```

---

### Experiment 2 — Virtual Queue as Demand Buffer

**What to test:** Compare direct booking load vs queue-buffered load on the booking service.

**Without queue:**
```
POST http://<ALB>/booking/api/v1/bookings
```

**With queue:**
```
POST http://<ALB>/queue/api/v1/queue/join
GET  http://<ALB>/queue/api/v1/queue/<queue_id>/status
# Once status == "admitted" → book
POST http://<ALB>/booking/api/v1/bookings
```

**What to measure:**
```bash
curl http://<ALB>/queue/api/v1/queue/evt-001/metrics
```
Key fields: `queue_depth`, `total_admitted`, `admission_rate_hz`.

**CloudWatch:** ECS CPU on booking-service — should be significantly lower in the queued scenario.

---

### Experiment 3 — Auto Scaling Under Ticket Drop Load

```bash
cd terraform/main

# Aggressive scaling (triggers sooner)
terraform apply -auto-approve \
  -var="autoscaling_cpu_target=50" \
  -var="lock_mode=pessimistic"

# Conservative scaling
terraform apply -auto-approve \
  -var="autoscaling_cpu_target=90"
```

**Load shape:** Near-zero → instant spike → sustained → drop-off. Use a Locust custom load shape class.

**What to watch:** ECS Service → Tasks tab, CloudWatch ECS CPUUtilization, ALB Target Group healthy host count.

**Runtime admission rate (no redeploy):**
```bash
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/admission-rate \
  -H "Content-Type: application/json" \
  -d '{"rate": 50}'
```

---

### Experiment 4 — Multiple Concurrent Flash Sales

Run simultaneous Locust workers targeting different events:

```
evt-001  Taylor Swift    (1000 seats)
evt-002  Coldplay        (500 seats)
evt-003  The Weeknd      (200 seats)
evt-004  Billie Eilish   (100 seats)
evt-005  Drake           (2000 seats)
```

**What to measure:**
```bash
curl http://<ALB>/booking/api/v1/events/evt-001/bookings
curl http://<ALB>/booking/api/v1/metrics?event_id=evt-001
```

---

### Experiment 5 — Multiple Requests from the Same User

Toggle `FAIRNESS_MODE` at runtime — no redeploy needed.

```bash
# Allow multiple queue slots per IP (higher throughput, less fair)
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/fairness-mode \
  -H "Content-Type: application/json" \
  -d '{"mode": "allow_multiple"}'

# Collapse to one slot per IP (fairer)
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/fairness-mode \
  -H "Content-Type: application/json" \
  -d '{"mode": "collapse"}'
```

---

## Useful Commands

```bash
# All Terraform outputs
cd terraform/main && terraform output

# Watch ECS task count live
watch -n 5 'aws ecs describe-services \
  --cluster concert-platform-booking-cluster \
  --services concert-platform-booking \
  --region us-east-1 \
  --query "services[0].runningCount"'

# Tail CloudWatch logs
aws logs tail /ecs/concert-platform-inventory   --follow --region us-east-1
aws logs tail /ecs/concert-platform-booking     --follow --region us-east-1
aws logs tail /ecs/concert-platform-queue       --follow --region us-east-1
aws logs tail /ecs/concert-platform-experiment1 --follow --region us-east-1

# Health checks
ALB=$(cd terraform/main && terraform output -raw alb_dns_name)
curl http://$ALB/inventory/health
curl http://$ALB/booking/health
curl http://$ALB/queue/health
curl http://$ALB/experiment1/health

# experiment1 Terraform outputs
cd experiments/experiment1/terraform && terraform output
```

---

## API Reference

### Inventory Service — `http://<ALB>/inventory`

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| GET | `/api/v1/events` | List all events |
| GET | `/api/v1/events/:event_id` | Get single event |
| GET | `/api/v1/events/:event_id/seats` | List seats |
| GET | `/api/v1/events/:event_id/availability` | Available seat count |

### Booking Service — `http://<ALB>/booking`

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/api/v1/bookings` | Create booking `{"event_id","seat_id","customer_id","lock_mode","db_backend"}` |
| GET | `/api/v1/bookings/:booking_id` | Get booking |
| GET | `/api/v1/events/:event_id/bookings` | List bookings for event |
| DELETE | `/api/v1/bookings/:booking_id` | Cancel booking |
| GET | `/api/v1/metrics?event_id=&db_backend=` | Live metrics (oversells, bookings/sec) |
| DELETE | `/api/v1/internal/events/:event_id/data` | Cleanup test data for event |

### Queue Service — `http://<ALB>/queue`

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/api/v1/queue/join` | Join queue `{"event_id","customer_id"}` |
| GET | `/api/v1/queue/status/:queue_id` | Check position and wait time |
| GET | `/api/v1/queue/metrics` | All queues metrics |
| GET | `/api/v1/queue/event/:event_id/metrics` | Single event queue metrics |
| POST | `/api/v1/queue/event/:event_id/admission-rate` | Change rate `{"rate":20}` |
| POST | `/api/v1/queue/event/:event_id/fairness-mode` | Change mode `{"mode":"collapse"}` |

### Experiment 1 Service — `http://<ALB>/experiment1`

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/api/v1/run` | Batch run `{"lock_mode","db_backend","concurrency","max_retries"}` |
| POST | `/api/v1/seat/init` | No-op — seat auto-initialises on first write |
| POST | `/api/v1/seat/book` | Single booking attempt `{"event_id","seat_id","booking_id","lock_mode","db_backend"}` |
| GET | `/api/v1/seat/results` | Get booking/oversell counts `?event_id=&seat_id=&db_backend=` |
| DELETE | `/api/v1/seat` | Cleanup seat data `?event_id=&seat_id=&db_backend=` |

---

## Seeded Events

| Event ID | Name | Venue | Seats |
|---|---|---|---|
| evt-001 | Taylor Swift - Eras Tour | Madison Square Garden | 1000 |
| evt-002 | Coldplay - Music of the Spheres | Fenway Park | 500 |
| evt-003 | The Weeknd - After Hours | TD Garden | 200 |
| evt-004 | Billie Eilish - Hit Me Hard | House of Blues | 100 |
| evt-005 | Drake - It's All a Blur | Gillette Stadium | 2000 |
