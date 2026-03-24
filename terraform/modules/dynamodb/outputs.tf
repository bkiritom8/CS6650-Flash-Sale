output "events_table_name"    { value = aws_dynamodb_table.events.name }
output "seats_table_name"     { value = aws_dynamodb_table.seats.name }
output "bookings_table_name"  { value = aws_dynamodb_table.bookings.name }
output "versions_table_name"  { value = aws_dynamodb_table.versions.name }
output "oversells_table_name" { value = aws_dynamodb_table.oversells.name }