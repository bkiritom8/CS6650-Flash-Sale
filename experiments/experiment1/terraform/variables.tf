variable "aws_region" {
  default = "us-east-1"
}

variable "service_name" {
  description = "Must match the main platform service_name so data sources find the right resources"
  default     = "concert-platform"
}

variable "container_port" {
  default = 8080
}

variable "log_retention_days" {
  default = 7
}

# ── Database ──────────────────────────────────────────────────────────────────

variable "db_password" {
  description = "Must match the password used when the main platform was deployed"
  default     = "TicketPass123!"
  sensitive   = true
}
