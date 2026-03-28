# ── Look up existing platform infrastructure ──────────────────────────────────
# Experiment 1 attaches to the VPC, ALB, and databases already provisioned by
# the main platform terraform. No shared state file is required — everything is
# located by the naming conventions the main terraform uses.

data "aws_vpc" "main" {
  tags = { Name = "${var.service_name}-vpc" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["${var.service_name}-private-*"]
  }
}

data "aws_security_group" "ecs" {
  name   = "${var.service_name}-ecs-sg"
  vpc_id = data.aws_vpc.main.id
}

data "aws_lb" "main" {
  name = "${var.service_name}-alb"
}

data "aws_lb_listener" "http" {
  load_balancer_arn = data.aws_lb.main.arn
  port              = 80
}

data "aws_db_instance" "mysql" {
  db_instance_identifier = "${var.service_name}-mysql"
}

data "aws_dynamodb_table" "bookings" {
  name = "${var.service_name}-bookings"
}

data "aws_dynamodb_table" "versions" {
  name = "${var.service_name}-seat-versions"
}

data "aws_dynamodb_table" "oversells" {
  name = "${var.service_name}-oversells"
}

# ── ECR repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "experiment1" {
  name                 = "${var.service_name}-experiment1"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = { Name = "${var.service_name}-experiment1" }
}

resource "aws_ecr_lifecycle_policy" "experiment1" {
  repository = aws_ecr_repository.experiment1.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 3 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}

# ── CloudWatch log group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "experiment1" {
  name              = "/ecs/${var.service_name}-experiment1"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${var.service_name}-experiment1-logs" }
}

# ── ALB target group + listener rule ─────────────────────────────────────────

resource "aws_lb_target_group" "experiment1" {
  name        = "${var.service_name}-exp1-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = { Name = "${var.service_name}-exp1-tg" }
}

resource "aws_lb_listener_rule" "experiment1" {
  listener_arn = data.aws_lb_listener.http.arn
  priority     = 40

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.experiment1.arn
  }

  condition {
    path_pattern { values = ["/experiment1/*"] }
  }
}

# ── ECS cluster, task definition, service ────────────────────────────────────

resource "aws_ecs_cluster" "experiment1" {
  name = "${var.service_name}-experiment1-cluster"
}

resource "aws_ecs_task_definition" "experiment1" {
  family                   = "${var.service_name}-experiment1"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  container_definitions = jsonencode([{
    name      = "${var.service_name}-experiment1"
    image     = "${aws_ecr_repository.experiment1.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [
      { name = "BOOKING_SERVICE_URL", value = "http://${data.aws_lb.main.dns_name}/booking" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.experiment1.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "${var.service_name}-experiment1"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:${var.container_port}/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

resource "aws_ecs_service" "experiment1" {
  name            = "${var.service_name}-experiment1"
  cluster         = aws_ecs_cluster.experiment1.id
  task_definition = aws_ecs_task_definition.experiment1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [data.aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.experiment1.arn
    container_name   = "${var.service_name}-experiment1"
    container_port   = var.container_port
  }

  # Force a fresh deployment whenever the task definition changes.
  force_new_deployment = true

  depends_on = [aws_lb_listener_rule.experiment1]
}
