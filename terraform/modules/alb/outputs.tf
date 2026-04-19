output "alb_dns_name"      { value = aws_lb.main.dns_name }
output "alb_arn"           { value = aws_lb.main.arn }
output "inventory_tg_arn"  { value = aws_lb_target_group.inventory.arn }
output "booking_tg_arn"    { value = aws_lb_target_group.booking.arn }
output "queue_tg_arn"      { value = aws_lb_target_group.queue.arn }
output "listener_arn"      { value = aws_lb_listener.http.arn }