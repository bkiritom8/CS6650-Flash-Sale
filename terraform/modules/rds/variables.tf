variable "service_name" {}
variable "subnet_ids"   { type = list(string) }
variable "rds_sg_id"    {}
variable "db_name"      {}
variable "db_username"  {}
variable "db_password"  { sensitive = true }