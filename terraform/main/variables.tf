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

variable "scaling_policy_type" { 
  description = "Autoscaling policy, either 'target_tracking' or 'step'"
  type = string
  default = "target_tracking" 
}

variable "scale_in_cooldown" { 
  default = 300
}

variable "scale_out_cooldown"{
  default = 60
}

variable "step_adjustments" {
  description = "List of step bounds and scaling adjustments for step autoscaling"
  type = list(object({
    metric_interval_lower_bound = number
    metric_interval_upper_bound = optional(number, null)
    scaling_adjustment          = number
  }))
  default = []
}

variable "alarm_cpu_threshold" {
  description = "Alarm threshold for CPU CloudWatch monitoring, for use with step autoscaling. Should be the same as autoscaling_cpu_target for testing purposes"
  default = 70
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