resource "aws_db_subnet_group" "main" {
  name       = "${var.service_name}-rds-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "main" {
  identifier        = "${var.service_name}-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]

  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  multi_az                = false

  tags = { Name = "${var.service_name}-mysql" }
}