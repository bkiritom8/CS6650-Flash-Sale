resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${var.cluster_name}/${var.service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scale out when average CPU across all tasks exceeds target
resource "aws_appautoscaling_policy" "cpu" {
  count              = var.scaling_policy_type == "target_tracking" ? 1 : 0
  name               = "${var.service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Scale out specific number of tasks when CPU exceeds given thresholds above alarm value
resource "aws_appautoscaling_policy" "step" {
  count              = var.scaling_policy_type == "step" ? 1 : 0
  name               = "${var.service_name}-cpu-step-scaling"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    dynamic "step_adjustment" {
      for_each = var.step_adjustments
      content {
        metric_interval_lower_bound = step_adjustment.value.metric_interval_lower_bound
        metric_interval_upper_bound = step_adjustment.value.metric_interval_upper_bound
        scaling_adjustment          = step_adjustment.value.scaling_adjustment
      }
    }
  }

}

resource "aws_cloudwatch_metric_alarm" "this" {
  count                     = var.scaling_policy_type == "step" ? 1 : 0
  alarm_name = "${var.service_name}-step-scaling-alarm"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/ECS"
  period                    = 30
  statistic                 = "Average"
  threshold                 = var.alarm_cpu_threshold
  dimensions                = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
  alarm_description         = "This metric monitors ecs cpu utilization"
  alarm_actions             = [aws_appautoscaling_policy.step[0].arn]
}