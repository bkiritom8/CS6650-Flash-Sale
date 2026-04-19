output "policy_arn" {
  value = var.scaling_policy_type == "step" ? aws_appautoscaling_policy.step[0].arn : var.scaling_policy_type == "target_tracking" ? aws_appautoscaling_policy.cpu[0].arn : "none"
}