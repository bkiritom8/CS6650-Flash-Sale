resource "aws_lb" "main" {
  name               = "${var.service_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids
  tags               = { Name = "${var.service_name}-alb" }
}

# ── Target groups (one per service) ──────────────────────────────────────────
resource "aws_lb_target_group" "inventory" {
  name        = "${var.service_name}-inv-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_target_group" "booking" {
  name        = "${var.service_name}-bk-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_target_group" "queue" {
  name        = "${var.service_name}-q-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

# ── Listener with path-based routing ─────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Default → booking service
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.booking.arn
  }
}

resource "aws_lb_listener_rule" "inventory" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.inventory.arn
  }
  condition {
    path_pattern { values = ["/inventory/*"] }
  }
}

resource "aws_lb_listener_rule" "queue" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.queue.arn
  }
  condition {
    path_pattern { values = ["/queue/*"] }
  }
}

resource "aws_lb_listener_rule" "booking" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.booking.arn
  }
  condition {
    path_pattern { values = ["/booking/*"] }
  }
}

