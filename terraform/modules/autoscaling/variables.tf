variable "service_name"      {}
variable "cluster_name"      {}
variable "min_capacity"      { default = 1 }
variable "max_capacity"      { default = 4 }
variable "cpu_target"        { default = 70 }
variable "scale_in_cooldown" { default = 300 }
variable "scale_out_cooldown"{ default = 60 }
variable "scaling_policy_type" { default = "target_tracking"}
variable "step_adjustments" {}
variable "alarm_cpu_threshold" { default = 70 }