# ── Network ───────────────────────────────────────────────────────────────────
module "network" {
  source         = "../modules/network"
  service_name   = var.service_name
  container_port = var.container_port
  aws_region     = var.aws_region
}

# ── ECR repositories (one per service) ───────────────────────────────────────
module "ecr_inventory" {
  source          = "../modules/ecr"
  repository_name = var.ecr_inventory_repo
}

module "ecr_booking" {
  source          = "../modules/ecr"
  repository_name = var.ecr_booking_repo
}

module "ecr_queue" {
  source          = "../modules/ecr"
  repository_name = var.ecr_queue_repo
}

# ── CloudWatch log groups ─────────────────────────────────────────────────────
module "logging_inventory" {
  source            = "../modules/logging"
  service_name      = "${var.service_name}-inventory"
  retention_in_days = var.log_retention_days
}

module "logging_booking" {
  source            = "../modules/logging"
  service_name      = "${var.service_name}-booking"
  retention_in_days = var.log_retention_days
}

module "logging_queue" {
  source            = "../modules/logging"
  service_name      = "${var.service_name}-queue"
  retention_in_days = var.log_retention_days
}

# ── RDS MySQL ─────────────────────────────────────────────────────────────────
module "rds" {
  source       = "../modules/rds"
  service_name = var.service_name
  subnet_ids   = module.network.private_subnet_ids
  rds_sg_id    = module.network.rds_sg_id
  db_name      = "concertdb"
  db_username  = "admin"
  db_password  = var.db_password
}

# ── DynamoDB tables ───────────────────────────────────────────────────────────
module "dynamodb" {
  source       = "../modules/dynamodb"
  service_name = var.service_name
}

# ── ALB (single, path-based routing to all three services) ───────────────────
module "alb" {
  source           = "../modules/alb"
  service_name     = var.service_name
  vpc_id           = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id        = module.network.alb_sg_id
  container_port   = var.container_port
}

# ── Docker builds & ECR pushes ────────────────────────────────────────────────
# platform = linux/amd64 ensures images built on Apple Silicon or ARM hosts
# are compatible with ECS Fargate (x86_64).
resource "docker_image" "inventory" {
  name = "${module.ecr_inventory.repository_url}:latest"
  build {
    context  = "../../src/inventory-service"
    platform = "linux/amd64"
  }
}
resource "docker_registry_image" "inventory" {
  name          = docker_image.inventory.name
  keep_remotely = true
}

resource "docker_image" "booking" {
  name = "${module.ecr_booking.repository_url}:latest"
  build {
    context  = "../../src/booking-service"
    platform = "linux/amd64"
  }
}
resource "docker_registry_image" "booking" {
  name          = docker_image.booking.name
  keep_remotely = true
}

resource "docker_image" "queue" {
  name = "${module.ecr_queue.repository_url}:latest"
  build {
    context  = "../../src/queue-service"
    platform = "linux/amd64"
  }
}
resource "docker_registry_image" "queue" {
  name          = docker_image.queue.name
  keep_remotely = true
}

# ── Inventory ECS service ─────────────────────────────────────────────────────
module "ecs_inventory" {
  source             = "../modules/ecs"
  service_name       = "${var.service_name}-inventory"
  image              = "${module.ecr_inventory.repository_url}:latest"
  container_port     = var.container_port
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.ecs_sg_id]
  execution_role_arn = data.aws_iam_role.lab_role.arn
  task_role_arn      = data.aws_iam_role.lab_role.arn
  log_group_name     = module.logging_inventory.log_group_name
  region             = var.aws_region
  cpu                = "256"
  memory             = "512"
  desired_count      = 1
  target_group_arn   = module.alb.inventory_tg_arn

  environment = [
    { name = "DB_BACKEND",              value = var.db_backend },
    { name = "AWS_REGION",              value = var.aws_region },
    { name = "MYSQL_HOST",              value = module.rds.host },
    { name = "MYSQL_PORT",              value = tostring(module.rds.port) },
    { name = "MYSQL_DB",                value = module.rds.db_name },
    { name = "MYSQL_USER",              value = "admin" },
    { name = "MYSQL_PASSWORD",          value = var.db_password },
    { name = "DYNAMODB_EVENTS_TABLE",   value = module.dynamodb.events_table_name },
    { name = "DYNAMODB_SEATS_TABLE",    value = module.dynamodb.seats_table_name },
  ]

  depends_on = [docker_registry_image.inventory, module.rds]
}

# ── Booking ECS service ───────────────────────────────────────────────────────
module "ecs_booking" {
  source             = "../modules/ecs"
  service_name       = "${var.service_name}-booking"
  image              = "${module.ecr_booking.repository_url}:latest"
  container_port     = var.container_port
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.ecs_sg_id]
  execution_role_arn = data.aws_iam_role.lab_role.arn
  task_role_arn      = data.aws_iam_role.lab_role.arn
  log_group_name     = module.logging_booking.log_group_name
  region             = var.aws_region
  cpu                = "256"
  memory             = "512"
  desired_count      = 1
  target_group_arn   = module.alb.booking_tg_arn

  environment = [
    { name = "DB_BACKEND",               value = var.db_backend },
    { name = "AWS_REGION",               value = var.aws_region },
    { name = "LOCK_MODE",                value = var.lock_mode },
    { name = "INVENTORY_SERVICE_URL",    value = "http://${module.alb.alb_dns_name}/inventory" },
    { name = "MYSQL_HOST",               value = module.rds.host },
    { name = "MYSQL_PORT",               value = tostring(module.rds.port) },
    { name = "MYSQL_DB",                 value = module.rds.db_name },
    { name = "MYSQL_USER",               value = "admin" },
    { name = "MYSQL_PASSWORD",           value = var.db_password },
    { name = "DYNAMODB_BOOKINGS_TABLE",  value = module.dynamodb.bookings_table_name },
    { name = "DYNAMODB_VERSIONS_TABLE",  value = module.dynamodb.versions_table_name },
    { name = "DYNAMODB_OVERSELLS_TABLE", value = module.dynamodb.oversells_table_name },
  ]

  depends_on = [docker_registry_image.booking, module.rds, module.ecs_inventory]
}

# ── Queue ECS service ─────────────────────────────────────────────────────────
module "ecs_queue" {
  source             = "../modules/ecs"
  service_name       = "${var.service_name}-queue"
  image              = "${module.ecr_queue.repository_url}:latest"
  container_port     = var.container_port
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.ecs_sg_id]
  execution_role_arn = data.aws_iam_role.lab_role.arn
  task_role_arn      = data.aws_iam_role.lab_role.arn
  log_group_name     = module.logging_queue.log_group_name
  region             = var.aws_region
  cpu                = "256"
  memory             = "512"
  desired_count      = 1
  target_group_arn   = module.alb.queue_tg_arn

  environment = [
    { name = "ADMISSION_RATE", value = tostring(var.admission_rate) },
    { name = "FAIRNESS_MODE",  value = var.fairness_mode },
  ]

  depends_on = [docker_registry_image.queue]
}

# ── Auto Scaling (booking service — Experiment 3) ─────────────────────────────
module "autoscaling" {
  source       = "../modules/autoscaling"
  service_name = "${var.service_name}-booking"
  cluster_name = module.ecs_booking.cluster_name
  min_capacity = var.autoscaling_min
  max_capacity = var.autoscaling_max
  cpu_target   = var.autoscaling_cpu_target

  depends_on = [module.ecs_booking]
}