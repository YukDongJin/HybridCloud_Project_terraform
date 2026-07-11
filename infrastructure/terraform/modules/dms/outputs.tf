output "replication_task_arn" {
  value = aws_dms_replication_task.db1_to_rds1.replication_task_arn
}

output "task_arn" {
  value = aws_dms_replication_task.db1_to_rds1.replication_task_arn
}

output "db1_to_rds1_task_arn" {
  value = aws_dms_replication_task.db1_to_rds1.replication_task_arn
}

output "rds1_to_rds2_task_arn" {
  value = aws_dms_replication_task.rds1_to_rds2.replication_task_arn
}

output "rds1_to_db1_task_arn" {
  value = aws_dms_replication_task.rds1_to_db1.replication_task_arn
}

output "rds2_to_rds1_task_arn" {
  value = aws_dms_replication_task.rds2_to_rds1.replication_task_arn
}