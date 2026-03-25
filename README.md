# Concert Ticket Platform

## Prerequisites

Install these before anything else:

- Go 1.21+
- Terraform 1.5+
- Docker Desktop (must be running)
- AWS CLI v2, configured with your student account credentials
- Python 3 (for smoke test parsing)
- `curl`

---

## Repository Structure

```
concert-ticket-platform/
├── src/
│   ├── inventory-service/   # Manages events and seats
│   ├── booking-service/     # Handles bookings + concurrency control
│   ├── queue-service/       # Virtual waiting room
│   └── experiment1/         # Experiment 1: concurrency control load test
│       ├── terraform/       # Self-contained infra (ECR, ECS, ALB rule)
│       └── scripts/         # deploy.sh, cleanup.sh, test.sh
├── terraform/
│   ├── main/                # Root config — run all Terraform from here
│   └── modules/             # alb, autoscaling, dynamodb, ecr, ecs, logging, network, rds
├── scripts/
│   ├── deploy.sh            # Full deploy: build images, push to ECR, provision AWS
│   ├── cleanup.sh           # Tear down all AWS resources
│   └── test-platform.sh     # Smoke test all endpoints after deploy
└── INSTRUCTIONS.md
```

---

## Environment Variables (key ones)

| Variable | Service | Values | Default |
|---|---|---|---|
| `DB_BACKEND` | inventory, booking | `mysql` \| `dynamodb` | `mysql` |
| `LOCK_MODE` | booking | `none` \| `optimistic` \| `pessimistic` | `pessimistic` |
| `ADMISSION_RATE` | queue | integer (admissions/sec) | `10` |
| `FAIRNESS_MODE` | queue | `collapse` \| `allow_multiple` | `allow_multiple` |
| `AUTOSCALING_CPU_TARGET` | Terraform var | integer (%) | `70` |
| `MYSQL_HOST` | experiment1 | RDS hostname | _(set by Terraform)_ |
| `DYNAMODB_BOOKINGS_TABLE` | experiment1 | DynamoDB table name | _(set by Terraform)_ |

All of these are Terraform variables too — override them in `terraform/main/variables.tf` or pass `-var` flags.

---

## Deploying the Platform

### Step 1 — Configure AWS credentials

```bash
export AWS_REGION=us-east-1
# Make sure `aws sts get-caller-identity` works before continuing
aws sts get-caller-identity
```

### Step 2 — Make scripts executable (first time only)

```bash
chmod +x scripts/deploy.sh scripts/cleanup.sh scripts/test-platform.sh
```

### Step 3 — Deploy everything

```bash
./scripts/deploy.sh
```

This will:
1. Run `go mod tidy` on all three platform services
2. Run `terraform init` and `terraform apply`
3. Build all three Docker images locally with `--platform linux/amd64`
4. Push them to ECR
5. Provision: VPC, NAT, ALB, RDS MySQL, DynamoDB (5 tables), ECS (3 services), CloudWatch
6. Wait for all health checks to pass

**Expected time: 8–12 minutes** (RDS takes the longest)

### Step 4 — Verify

```bash
./scripts/test-platform.sh
```

This runs a full smoke test — health checks, all endpoints, a real booking, a real queue join. You should see all `[PASS]` before handing off to teammates.

For experiment1 specifically: `./src/experiment1/scripts/test.sh`

---

## Switching Database Backend

To switch between MySQL and DynamoDB without redeploying from scratch:

```bash
cd terraform/main
terraform apply -auto-approve -var="db_backend=dynamodb"
# Wait for ECS to stabilise (~2-3 min)
aws ecs wait services-stable \
  --cluster concert-platform-booking-cluster \
  --services concert-platform-booking \
  --region us-east-1
```

Switch back:
```bash
terraform apply -auto-approve -var="db_backend=mysql"
```

---

## Tearing Down

```bash
./scripts/cleanup.sh
```

Type `yes` when prompted. This destroys everything — NAT Gateway, RDS, ECS, ECR, DynamoDB.

---

## Experiment Guide

All experiments are controlled through environment variables passed to Terraform or via the runtime API endpoints on the queue service. No Go code changes are needed for any experiment.

### Experiment 1 — Concurrency Control Under Flash Sale Load

**Service:** `http://<ALB>/experiment1`

Simulates N users (default 1000) simultaneously booking the last available seat.
Tests three strategies against both MySQL (RDS) and DynamoDB in a single HTTP call.
Has its own Terraform and scripts — deploy and tear down independently of the main platform.

**Deploy experiment1 (run main platform deploy first):**
```bash
# Deploy
cd src/experiment1
./scripts/deploy.sh

# Run all tests (correctness assertions + all 6 mode×backend combos)
./scripts/test.sh

# Tear down experiment1 only (main platform untouched)
./scripts/cleanup.sh
```

**Run an experiment:**
```bash
ALB=$(cd terraform/main && terraform output -raw alb_dns_name)

# Baseline — no concurrency control (oversells expected)
curl -s -X POST http://$ALB/experiment1/api/v1/run \
  -H "Content-Type: application/json" \
  -d '{"lock_mode":"none","db_backend":"mysql","concurrency":1000}' | jq .

# Optimistic locking — MySQL
curl -s -X POST http://$ALB/experiment1/api/v1/run \
  -H "Content-Type: application/json" \
  -d '{"lock_mode":"optimistic","db_backend":"mysql","concurrency":1000,"max_retries":3}' | jq .

# Pessimistic locking — MySQL
curl -s -X POST http://$ALB/experiment1/api/v1/run \
  -H "Content-Type: application/json" \
  -d '{"lock_mode":"pessimistic","db_backend":"mysql","concurrency":1000}' | jq .

# All three modes — DynamoDB (swap db_backend)
curl -s -X POST http://$ALB/experiment1/api/v1/run \
  -H "Content-Type: application/json" \
  -d '{"lock_mode":"none","db_backend":"dynamodb","concurrency":1000}' | jq .
```

**Response fields:**

| Field | Description |
|---|---|
| `successful_bookings` | Goroutines that wrote a booking |
| `failed_bookings` | Goroutines that got a conflict/retry-exhausted error |
| `oversell_count` | DB-verified double-bookings (should be 0 for optimistic/pessimistic) |
| `oversell_rate_pct` | `oversell_count / concurrency × 100` |
| `total_duration_ms` | Wall time from first goroutine start to last finish |
| `latency_ms.min/max/mean/p99` | Per-attempt latency across all goroutines |

**Expected results:**

| Strategy | Backend | Successful | Oversells | Latency |
|---|---|---|---|---|
| `none` | MySQL | ~1000 | ~999 | Low |
| `optimistic` | MySQL | 1 | 0 | Medium (retries) |
| `pessimistic` | MySQL | 1 | 0 | High (serialised lock) |
| `none` | DynamoDB | ~1000 | ~999 | Low |
| `optimistic` | DynamoDB | 1 | 0 | Medium |
| `pessimistic` | DynamoDB | 1 | 0 | Medium (atomic txn) |

**How it works internally:**
- Each run generates a unique `event_id` so runs never interfere.
- All goroutines block on a shared channel then release simultaneously to maximise contention.
- MySQL pessimistic uses `SELECT ... FOR UPDATE` (row-level lock, queuing writers).
- DynamoDB pessimistic uses `TransactWriteItems` (atomic condition-check + update + put).
- After the run, data is cleaned up automatically.

**CloudWatch logs:**
```bash
aws logs tail /ecs/concert-platform-experiment1 --follow --region us-east-1
```

**Terraform (experiment1 only):**
```bash
cd src/experiment1/terraform
terraform output          # show URL, ECR repo, cluster name
terraform destroy         # remove experiment1 infra only
```

---

### Experiment 2 — Virtual Queue as Demand Buffer

**What to test:** Compare direct booking load (bypass queue) vs queue-buffered load.

**Without queue:** Send Locust traffic directly to:
```
POST http://<ALB>/booking/api/v1/bookings
```

**With queue:** Send Locust traffic to join queue first, then poll for admission:
```
POST http://<ALB>/queue/api/v1/queue/join
GET  http://<ALB>/queue/api/v1/queue/<queue_id>/status
# Once status == "admitted", proceed to book
POST http://<ALB>/booking/api/v1/bookings
```

**What to measure:**
```bash
# Queue depth during load
curl http://<ALB>/queue/api/v1/queue/evt-001/metrics
```
Key fields: `queue_depth`, `total_admitted`, `admission_rate_hz`.

**CloudWatch:** ECS CPU on booking-service — should be much lower in the queued scenario.

---

### Experiment 3 — Auto Scaling Under Ticket Drop Load

**What to change:** CPU target threshold and cooldown periods via Terraform.

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

**Load shape to simulate:** Near-zero → instant spike → sustained → drop-off.
Use Locust with a custom load shape class for this.

**What to watch in AWS Console:**
- ECS Service → Tasks tab (watch task count climb)
- CloudWatch → ECS → CPUUtilization per service
- ALB → Target Group → Healthy host count

**Runtime admission rate change (no redeploy needed):**
```bash
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/admission-rate \
  -H "Content-Type: application/json" \
  -d '{"rate": 50}'
```

---

### Experiment 4 — Multiple Concurrent Flash Sales

**What to test:** Run simultaneous Locust campaigns targeting different events.

Use all 5 pre-seeded events:
```
evt-001  Taylor Swift    (1000 seats)
evt-002  Coldplay        (500 seats)
evt-003  The Weeknd      (200 seats)
evt-004  Billie Eilish   (100 seats)
evt-005  Drake           (2000 seats)
```

Run separate Locust workers per event and check whether load bleeds across.

**What to measure:** Per-event response times and booking success rates from:
```bash
curl http://<ALB>/booking/api/v1/events/evt-001/bookings
curl http://<ALB>/booking/api/v1/events/evt-002/bookings
# etc.
```

---

### Experiment 5 — Multiple Requests from the Same User

**What to change:** `FAIRNESS_MODE` — toggle at runtime, no redeploy needed.

```bash
# Allow multiple queue slots per IP (default — higher throughput)
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/fairness-mode \
  -H "Content-Type: application/json" \
  -d '{"mode": "allow_multiple"}'

# Collapse to one slot per IP (fairer)
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/fairness-mode \
  -H "Content-Type: application/json" \
  -d '{"mode": "collapse"}'
```

**What to measure:** Queue position distribution and throughput from:
```bash
curl http://<ALB>/queue/api/v1/queue/evt-001/metrics
```
Key fields: `queue_depth`, `total_admitted`, `fairness_mode`.

---

## Useful Commands

```bash
# Get all Terraform outputs
cd terraform/main && terraform output

# Watch ECS service task count live
watch -n 5 'aws ecs describe-services \
  --cluster concert-platform-booking-cluster \
  --services concert-platform-booking \
  --region us-east-1 \
  --query "services[0].runningCount"'

# Tail CloudWatch logs for booking service
aws logs tail /ecs/concert-platform-booking --follow --region us-east-1

# Tail CloudWatch logs for inventory service
aws logs tail /ecs/concert-platform-inventory --follow --region us-east-1

# Tail CloudWatch logs for queue service
aws logs tail /ecs/concert-platform-queue --follow --region us-east-1

# Check ALB DNS
cd terraform/main && terraform output alb_dns_name

# Manual health checks
ALB=$(cd terraform/main && terraform output -raw alb_dns_name)
curl http://$ALB/inventory/health
curl http://$ALB/booking/health
curl http://$ALB/queue/health
curl http://$ALB/experiment1/health

# Tail CloudWatch logs for experiment1
aws logs tail /ecs/concert-platform-experiment1 --follow --region us-east-1
```

---

## Full API Reference

### Inventory Service — `http://<ALB>/inventory`

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| GET | `/api/v1/events` | List all events |
| GET | `/api/v1/events/:event_id` | Get single event |
| GET | `/api/v1/events/:event_id/seats` | List seats for event |
| GET | `/api/v1/events/:event_id/availability` | Available seat count |

### Booking Service — `http://<ALB>/booking`

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/api/v1/bookings` | Create booking `{"event_id","seat_id","customer_id"}` |
| GET | `/api/v1/bookings/:booking_id` | Get booking |
| GET | `/api/v1/events/:event_id/bookings` | List bookings for event |
| DELETE | `/api/v1/bookings/:booking_id` | Cancel booking |
| GET | `/api/v1/metrics?event_id=` | Live metrics (oversells, bookings/sec, lock_mode) |

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
| POST | `/api/v1/run` | Run concurrency experiment `{"lock_mode","db_backend","concurrency","max_retries"}` |

---

## Seeded Events (available immediately after deploy)

| Event ID | Name | Venue | Seats |
|---|---|---|---|
| evt-001 | Taylor Swift - Eras Tour | Madison Square Garden | 1000 |
| evt-002 | Coldplay - Music of the Spheres | Fenway Park | 500 |
| evt-003 | The Weeknd - After Hours | TD Garden | 200 |
| evt-004 | Billie Eilish - Hit Me Hard | House of Blues | 100 |
| evt-005 | Drake - It's All a Blur | Gillette Stadium | 2000 |
