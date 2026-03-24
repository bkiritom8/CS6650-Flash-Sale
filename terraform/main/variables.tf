variable "aws_region" {
  default = "us-east-1"
}

variable "service_name" {
  default = "concert-platform"
}

variable "container_port" {
  default = 8080
}

variable "log_retention_days" {
  default = 7
}

# ── Database ──────────────────────────────────────────────────────────────────

variable "db_password" {
  default   = "TicketPass123!"
  sensitive = true
}

variable "db_backend" {
  description = "Storage backend: mysql or dynamodb"
  default     = "mysql"
}

# ── Concurrency control (Experiment 1) ───────────────────────────────────────

variable "lock_mode" {
  description = "Booking concurrency mode: none | optimistic | pessimistic"
  default     = "pessimistic"
}

# ── Queue service (Experiments 2, 3, 5) ──────────────────────────────────────

variable "admission_rate" {
  description = "Queue admissions per second"
  default     = 10
}

variable "fairness_mode" {
  description = "Queue fairness: collapse | allow_multiple"
  default     = "allow_multiple"
}

# ── Auto scaling (Experiment 3) ───────────────────────────────────────────────

variable "autoscaling_min" {
  default = 1
}

variable "autoscaling_max" {
  default = 4
}

variable "autoscaling_cpu_target" {
  description = "Target CPU % to trigger scale-out"
  default     = 70
}

# ── ECR repository names ───────────────────────────────────────────────────────

variable "ecr_inventory_repo" {
  default = "concert-inventory-service"
}

variable "ecr_booking_repo" {
  default = "concert-booking-service"
}

variable "ecr_queue_repo" {
  default = "concert-queue-service"
}