variable "service_name"       {}
variable "image"              {}
variable "container_port"     { default = 8080 }
variable "subnet_ids"         { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "execution_role_arn" {}
variable "task_role_arn"      {}
variable "log_group_name"     {}
variable "region"             {}
variable "cpu"                { default = "256" }
variable "memory"             { default = "512" }
variable "desired_count"      { default = 1 }
variable "target_group_arn"   {}
variable "environment" {
  type = list(object({ name = string, value = string }))
  default = []
}