output "experiment1_url" {
  value = "http://${data.aws_lb.main.dns_name}/experiment1"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.experiment1.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.experiment1.name
}

output "ecs_service_name" {
  value = aws_ecs_service.experiment1.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.experiment1.name
}

output "mongodb_private_ip" {
  value = aws_instance.mongodb.private_ip
}
