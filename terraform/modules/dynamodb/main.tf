# All tables use PAY_PER_REQUEST (on-demand) to avoid throttling during flash
# sale experiments while keeping costs bounded — no capacity planning needed.

resource "aws_dynamodb_table" "events" {
  name         = "${var.service_name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = { Name = "${var.service_name}-events" }
}

resource "aws_dynamodb_table" "seats" {
  name         = "${var.service_name}-seats"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "seat_id"

  attribute {
    name = "seat_id"
    type = "S"
  }

  attribute {
    name = "event_id"
    type = "S"
  }

  global_secondary_index {
    name            = "event_id-index"
    hash_key        = "event_id"
    projection_type = "ALL"
  }

  tags = { Name = "${var.service_name}-seats" }
}

resource "aws_dynamodb_table" "bookings" {
  name         = "${var.service_name}-bookings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "booking_id"

  attribute {
    name = "booking_id"
    type = "S"
  }

  attribute {
    name = "event_id"
    type = "S"
  }

  global_secondary_index {
    name            = "event_id-index"
    hash_key        = "event_id"
    projection_type = "ALL"
  }

  tags = { Name = "${var.service_name}-bookings" }
}

# Seat versions — used by optimistic and pessimistic locking in booking-service
resource "aws_dynamodb_table" "versions" {
  name         = "${var.service_name}-seat-versions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"
  range_key    = "seat_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "seat_id"
    type = "S"
  }

  tags = { Name = "${var.service_name}-seat-versions" }
}

# Oversell events — Experiment 1 metrics
resource "aws_dynamodb_table" "oversells" {
  name         = "${var.service_name}-oversells"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "oversell_id"

  attribute {
    name = "oversell_id"
    type = "S"
  }

  attribute {
    name = "event_id"
    type = "S"
  }

  global_secondary_index {
    name            = "event_id-index"
    hash_key        = "event_id"
    projection_type = "ALL"
  }

  tags = { Name = "${var.service_name}-oversells" }
}