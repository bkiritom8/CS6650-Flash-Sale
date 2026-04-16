variable "service_name"      {}
variable "vpc_id"            {}
variable "public_subnet_ids" { type = list(string) }
variable "alb_sg_id"         {}
variable "container_port"    { default = 8080 }