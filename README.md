# Concert Ticket Booking Platform

A distributed systems research project simulating a concert ticket flash sale backend. Five experiments study how architectural decisions affect system behavior under extreme load.

---

## Prerequisites

- Go 1.21+
- Terraform 1.5+
- Docker Desktop (must be running)
- AWS CLI v2 configured with student account credentials
- Python 3 + Locust (`pip install locust`)
- `curl`

---

## Repository Structure

```
CS6650-Flash-Sale/
│
├── experiments/                        # Experiment scripts and load test files
│   ├── experiment1/                    # Concurrency control under flash sale load
│   │   ├── experiment1.py              # Locust load test — waiting-room spawn pattern
│   │   ├── parse_stats.py              # Parses Locust CSV output for the test script
│   │   ├── generate_chart.py           # Generates PNG results chart from CSV
│   │   └── requirements.txt            # Python dependencies (locust)
│   │
│   ├── experiment2/                    # Virtual queue as demand buffer
│   │   ├── locustfile.py               # Locust load test — direct and queued scenarios
│   │   └── parse_stats.py              # Parses Locust CSV output for the test script
│   │
│   └── experiment4/                    # Multiple concurrent flash sales
│       ├── locustfile.py               # Locust load test — 5 weighted user classes
│       └── parse_stats.py              # Parses per-event stats from Locust CSV
│
├── powershell_scripts/                 # Windows PowerShell equivalents (for reference)
│   ├── deploy.ps1
│   ├── cleanup.ps1
│   ├── exp2-locust-test.ps1
│   └── test-platform.ps1
│
├── results/                            # Auto-generated experiment results (CSV + PNG)
│
├── scripts/                            # Main automation scripts (bash, cross-platform)
│   ├── deploy.sh                       # Build images, push to ECR, provision all AWS infra
│   ├── cleanup.sh                      # Tear down all AWS resources
│   ├── test-platform.sh                # Smoke test — verifies all endpoints after deploy
│   ├── exp1-locust-test.sh             # Run Experiment 1 (all lock modes x both backends)
│   ├── exp2-locust-test.sh             # Run Experiment 2 (direct vs queued x both backends)
│   └── exp4-locust-test.sh             # Run Experiment 4 (5 events x 2 user counts x both backends)
│
├── src/                                # Go microservices
│   ├── inventory-service/              # Manages events and seat availability
│   │   ├── main.go
│   │   ├── handler.go
│   │   ├── repository.go               # Storage interface
│   │   ├── mysql_repo.go               # MySQL implementation
│   │   ├── dynamodb_repo.go            # DynamoDB implementation
│   │   ├── models.go
│   │   ├── Dockerfile
│   │   └── go.mod
│   │
│   ├── booking-service/                # Handles bookings + concurrency control
│   │   ├── main.go
│   │   ├── handler.go
│   │   ├── repository.go               # Storage interface
│   │   ├── mysql_repo.go               # MySQL (no-lock, optimistic, pessimistic)
│   │   ├── dynamodb_repo.go            # DynamoDB (conditional write locking)
│   │   ├── models.go
│   │   ├── Dockerfile
│   │   └── go.mod
│   │
│   └── queue-service/                  # Virtual waiting room with admission rate control
│       ├── main.go
│       ├── handler.go
│       ├── queue.go                    # In-memory queue with fairness mode support
│       ├── models.go
│       ├── Dockerfile
│       └── go.mod
│
├── terraform/                          # Infrastructure as code (AWS, us-east-1)
│   ├── main/                           # Root Terraform config — run all commands from here
│   │   ├── main.tf                     # Wires all modules together
│   │   ├── variables.tf                # All tunable parameters (backend, lock mode, etc.)
│   │   ├── outputs.tf                  # ALB URL, table names, log groups
│   │   └── provider.tf                 # AWS + Docker providers, ECR auth
│   │
│   └── modules/                        # Reusable Terraform modules
│       ├── network/                    # VPC, subnets, NAT gateway, security groups
│       ├── ecr/                        # ECR repositories (one per service)
│       ├── ecs/                        # ECS Fargate cluster + service + task definition
│       ├── rds/                        # RDS MySQL (db.t3.micro)
│       ├── dynamodb/                   # DynamoDB tables (events, seats, bookings, versions)
│       ├── alb/                        # ALB with path-based routing to all three services
│       ├── autoscaling/                # CPU-based autoscaling for booking service
│       └── logging/                    # CloudWatch log groups
│
├── .gitignore
├── LICENSE
└── README.md
```

---

## Quick Start

### Step 1 — Configure AWS credentials

```bash
export AWS_REGION=us-east-1
aws sts get-caller-identity   # verify credentials work
```

### Step 2 — Make scripts executable (first time only, Mac/Linux)

```bash
chmod +x scripts/deploy.sh scripts/cleanup.sh scripts/test-platform.sh \
         scripts/exp1-locust-test.sh scripts/exp2-locust-test.sh \
         scripts/exp4-locust-test.sh
```

### Step 3 — Deploy

```bash
./scripts/deploy.sh
```

This builds all Docker images (`--platform linux/amd64` — works on ARM Macs too), pushes to ECR, and provisions all AWS infrastructure. Expected time: 8-12 minutes on first run.

### Step 4 — Verify

```bash
./scripts/test-platform.sh
```

### Step 5 — Run Dashboard (Frontend & Experiment Runner)

```bash
cd dashboard
npm install       # first time only
npm run dev:all
```

Open `http://localhost:5173` in your browser. 
- The default view is the **Fan View**. 
- To access the **Analytics** and built-in **Experiments** panels, click on the **Admin Control** tab and enter the password: `admin`.

### Step 6 — Tear down when done

```bash
./scripts/cleanup.sh
```

Always run this at the end of a session to stop RDS and NAT Gateway charges.

---

## Key Configuration

All experiment parameters are runtime configurable — no code changes needed.

| Variable | Default | Description |
|---|---|---|
| `DB_BACKEND` | `mysql` | Storage backend: `mysql` or `dynamodb` |
| `LOCK_MODE` | `pessimistic` | Booking concurrency: `none`, `optimistic`, `pessimistic` |
| `ADMISSION_RATE` | `10` | Queue admissions per second |
| `FAIRNESS_MODE` | `allow_multiple` | Queue fairness: `collapse` or `allow_multiple` |

Switch backends without redeploying:
```bash
cd terraform/main
terraform apply -auto-approve -var="db_backend=dynamodb"
```

> **Note:** `lock_mode` and `db_backend` can also be passed per-request in the booking API — Experiment 1 uses this to test all 6 combinations in a single run without redeploying.

---

## Experiment Guide

### Experiment 1 — Concurrency Control Under Flash Sale Load

Tests three locking strategies against both backends with all users simultaneously rushing the same seat.

| Variable | Default | Description |
|---|---|---|
| `CONCURRENCY` | `1000` | Number of concurrent users |
| `SPAWN_RATE` | `1000` | Users spawned per second |
| `RUN_TIME` | `120s` | Test duration |
| `BACKENDS` | `mysql dynamodb` | Backends to test |

```bash
# Run all 6 combinations (mysql×3 + dynamodb×3)
bash scripts/exp1-locust-test.sh

# Override concurrency
CONCURRENCY=1000 bash scripts/exp1-locust-test.sh

# Single backend only
BACKENDS="mysql" bash scripts/exp1-locust-test.sh
```

Results saved to `results/exp1_<timestamp>.csv` and `.png`.

**Note:** 409 responses mean seat taken — not a connectivity issue. Under no-lock mode, oversells occur instead. Under optimistic/pessimistic, all but one user gets 409.

---

### Experiment 2 — Virtual Queue as Demand Buffer

Compares direct booking (unbuffered) versus queue-buffered booking under flash sale load, across both backends.

| Variable | Default | Description |
|---|---|---|
| `USERS` | `500` | Number of concurrent users |
| `SPAWN_RATE` | `200` | Users spawned per second |
| `RUN_TIME` | `120s` | Test duration |
| `EVENT_ID` | `evt-001` | Event to target |
| `BACKENDS` | `mysql dynamodb` | Backends to test |
| `QUEUE_POLL_INTERVAL` | `5` | Seconds between queue status polls |

```bash
bash scripts/exp2-locust-test.sh
```

Queue metrics are polled every 5 seconds during queued tests and saved to `.tmp/exp2_locust/*_queue_metrics.jsonl`.

**Note:** 409 responses in this experiment are MySQL deadlocks from pessimistic locking under concurrent load — not failures. The queued scenario should produce significantly fewer 409s since requests arrive at a controlled rate.

---

### Experiment 3 — Auto Scaling Under Ticket Drop Load

Vary CPU target thresholds and cooldown periods to find configurations that handle a sudden spike without over-provisioning.

```bash
cd terraform/main

# Aggressive scaling (triggers sooner)
terraform apply -auto-approve -var="autoscaling_cpu_target=50"

# Conservative scaling
terraform apply -auto-approve -var="autoscaling_cpu_target=90"
```

Use a Locust custom `LoadTestShape` class to simulate the ticket drop load profile: near-zero traffic → instant spike → sustained peak → drop-off.

Watch in AWS Console: ECS Service Tasks tab, CloudWatch ECS CPUUtilization, ALB Target Group healthy host count.

Change admission rate at runtime without redeploying:
```bash
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/admission-rate \
  -H "Content-Type: application/json" -d '{"rate": 50}'
```

---

### Experiment 4 — Multiple Concurrent Flash Sales

Runs all 5 events simultaneously with weighted user distribution to test whether high load on one event bleeds into others.

| Variable | Default | Description |
|---|---|---|
| `USERS_LOW` | `500` | Low concurrency run |
| `USERS_HIGH` | `1000` | High concurrency run |
| `SPAWN_RATE` | `50` | Users spawned per second |
| `RUN_TIME` | `120s` | Test duration per run |
| `BACKENDS` | `mysql dynamodb` | Backends to test |

```bash
# Run all 4 combinations (2 backends x 2 user counts)
bash scripts/exp4-locust-test.sh

# Override user counts
USERS_LOW=500 USERS_HIGH=1000 bash scripts/exp4-locust-test.sh
```

User distribution across events:
| Event | Demand | Weight |
|---|---|---|
| evt-001 Taylor Swift | HIGH | ~40% of users |
| evt-005 Drake | MODERATE | ~25% of users |
| evt-002 Coldplay | | ~15% of users |
| evt-003 The Weeknd | | ~12% of users |
| evt-004 Billie Eilish | LOW | ~8% of users |

**Key finding to look for:** Compare evt-004 p95 latency at 500 vs 1000 users. If it degrades more than evt-001, load is bleeding across event boundaries through shared infrastructure (MySQL connection pool or DynamoDB table throughput).

Results saved to `results/exp4_<timestamp>.csv`.

---

### Experiment 5 — Multiple Requests from the Same User

Toggle fairness mode at runtime — no redeploy needed.

```bash
# Allow multiple queue slots per IP (higher throughput, less fair)
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/fairness-mode \
  -H "Content-Type: application/json" -d '{"mode": "allow_multiple"}'

# Collapse to one slot per IP (fairer)
curl -X POST http://<ALB>/queue/api/v1/queue/event/evt-001/fairness-mode \
  -H "Content-Type: application/json" -d '{"mode": "collapse"}'
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
aws logs tail /ecs/concert-platform-inventory --follow --region us-east-1
aws logs tail /ecs/concert-platform-booking   --follow --region us-east-1
aws logs tail /ecs/concert-platform-queue     --follow --region us-east-1

# Manual health checks
ALB=$(cd terraform/main && terraform output -raw alb_dns_name)
curl http://$ALB/inventory/health
curl http://$ALB/booking/health
curl http://$ALB/queue/health
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
| POST | `/api/v1/reset` | Reset all booking and inventory data |
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

---

## Seeded Events

| Event ID | Name | Venue | Seats |
|---|---|---|---|
| evt-001 | Taylor Swift - Eras Tour | Madison Square Garden | 1000 |
| evt-002 | Coldplay - Music of the Spheres | Fenway Park | 500 |
| evt-003 | The Weeknd - After Hours | TD Garden | 200 |
| evt-004 | Billie Eilish - Hit Me Hard | House of Blues | 100 |
| evt-005 | Drake - It's All a Blur | Gillette Stadium | 2000 |
