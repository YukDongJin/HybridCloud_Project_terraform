output "health_monitor_arn" {
  value = aws_lambda_function.health_monitor.arn
}

output "failover_controller_arn" {
  value = aws_lambda_function.failover_controller.arn
}

output "dms_chain_starter_arn" {
  value = aws_lambda_function.dms_chain_starter.arn
}
