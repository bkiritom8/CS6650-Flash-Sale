output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "inventory_url" {
  value = "http://${module.alb.alb_dns_name}/inventory"
}

output "booking_url" {
  value = "http://${module.alb.alb_dns_name}/booking"
}

output "queue_url" {
  value = "http://${module.alb.alb_dns_name}/queue"
}

output "rds_endpoint" {
  value = module.rds.host
}

output "dynamodb_events_table" {
  value = module.dynamodb.events_table_name
}

output "dynamodb_seats_table" {
  value = module.dynamodb.seats_table_name
}

output "dynamodb_bookings_table" {
  value = module.dynamodb.bookings_table_name
}

output "inventory_log_group" {
  value = module.logging_inventory.log_group_name
}

output "booking_log_group" {
  value = module.logging_booking.log_group_name
}

output "queue_log_group" {
  value = module.logging_queue.log_group_name
}