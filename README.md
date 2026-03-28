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
│   └── queue-service/       # Virtual waiting room
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
1. Run `go mod tidy` on all three services
2. Run `terraform init` and `terraform apply`
3. Build all three Docker images locally
4. Push them to ECR
5. Provision: VPC, NAT, ALB, RDS MySQL, DynamoDB (5 tables), ECS (3 services), CloudWatch
6. Wait for all health checks to pass

**Expected time: 8–12 minutes** (RDS takes the longest)

### Step 4 — Verify

```bash
./scripts/test-platform.sh
```

<<<<<<< HEAD
This runs a full smoke test — health checks, all endpoints, a real booking, a real queue join. You should see all `[PASS]` before handing off to teammates.
=======
This runs a smoke test.
>>>>>>> 2a97134d320d594889aeaabebcd91464202f2163

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

<<<<<<< HEAD
## TO DO — Experiment Guide
=======
## FUTURE WORK — Experiment Guide
>>>>>>> 2a97134d320d594889aeaabebcd91464202f2163

All experiments are controlled through environment variables passed to Terraform or via the runtime API endpoints on the queue service. No Go code changes are needed for any experiment.

### Experiment 1 — Concurrency Control

**What to change:** `LOCK_MODE` on the booking service.

```bash
cd terraform/main

# Baseline — no concurrency control (oversells expected)
terraform apply -auto-approve -var="lock_mode=none"

# Optimistic locking
terraform apply -auto-approve -var="lock_mode=optimistic"

# Pessimistic locking (default)
terraform apply -auto-approve -var="lock_mode=pessimistic"
```

**What to measure:** Hit `POST /booking/api/v1/bookings` concurrently with Locust.
After each run, check oversell count:
```bash
curl http://<ALB>/booking/api/v1/metrics?event_id=evt-001
```
Key fields: `oversell_count`, `bookings_per_sec`, `lock_mode`.

**CloudWatch metrics to capture:** ECS CPU, response time from ALB target group.

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
| POST | `/api/v1/reset` | Reset all booking data (also resets inventory) |

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

## Seeded Events (available immediately after deploy)

| Event ID | Name | Venue | Seats |
|---|---|---|---|
| evt-001 | Taylor Swift - Eras Tour | Madison Square Garden | 1000 |
| evt-002 | Coldplay - Music of the Spheres | Fenway Park | 500 |
| evt-003 | The Weeknd - After Hours | TD Garden | 200 |
| evt-004 | Billie Eilish - Hit Me Hard | House of Blues | 100 |
| evt-005 | Drake - It's All a Blur | Gillette Stadium | 2000 |
