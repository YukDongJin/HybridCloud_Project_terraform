# CloudWatch 알람 - EC2 DB1 (실시간 모니터링)
resource "aws_cloudwatch_metric_alarm" "ec2_db1_health" {
  alarm_name          = "${var.project_name}-ec2-db1-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DBHealthStatus"
  namespace           = "DBMigration/Failover"
  period              = 60  # 1분마다 체크
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "EC2 DB1 health check failure - triggers failover to RDS1"
  treat_missing_data  = "breaching"  # 데이터 없으면 장애로 간주
  
  alarm_actions       = [var.sns_topic_arn, var.failover_controller_lambda_arn]
  ok_actions          = [var.sns_topic_arn, var.failover_controller_lambda_arn]  # 복구 시에도 알림

  dimensions = {
    DBInstance = "ec2_db1"
  }

  tags = {
    Name = "${var.project_name}-ec2-db1-alarm"
  }
}

# CloudWatch 알람 - RDS1 (실시간 모니터링)
resource "aws_cloudwatch_metric_alarm" "rds1_health" {
  alarm_name          = "${var.project_name}-rds1-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DBHealthStatus"
  namespace           = "DBMigration/Failover"
  period              = 60  # 1분마다 체크
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "RDS1 health check failure - triggers failover to RDS2"
  treat_missing_data  = "breaching"
  
  alarm_actions       = [var.sns_topic_arn, var.failover_controller_lambda_arn]
  ok_actions          = [var.sns_topic_arn, var.failover_controller_lambda_arn]

  dimensions = {
    DBInstance = "rds1"
  }

  tags = {
    Name = "${var.project_name}-rds1-alarm"
  }
}

# CloudWatch 알람 - RDS2 (실시간 모니터링)
resource "aws_cloudwatch_metric_alarm" "rds2_health" {
  alarm_name          = "${var.project_name}-rds2-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DBHealthStatus"
  namespace           = "DBMigration/Failover"
  period              = 60  # 1분마다 체크
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "RDS2 health check failure - critical alert"
  treat_missing_data  = "breaching"
  
  alarm_actions       = [var.sns_topic_arn, var.failover_controller_lambda_arn]
  ok_actions          = [var.sns_topic_arn, var.failover_controller_lambda_arn]

  dimensions = {
    DBInstance = "rds2"
  }

  tags = {
    Name = "${var.project_name}-rds2-alarm"
  }
}

# CloudWatch 알람 - 복제 지연 (실시간 모니터링)
resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  alarm_name          = "${var.project_name}-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicationLag"
  namespace           = "DBMigration/Failover"
  period              = 60  # 1분마다 체크
  statistic           = "Average"
  threshold           = 10  # 10초 이상 지연 시 알림
  alarm_description   = "Replication lag exceeds 10 seconds"
  treat_missing_data  = "notBreaching"
  
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  tags = {
    Name = "${var.project_name}-replication-lag-alarm"
  }
}

# CloudWatch 알람 - RDS CPU 사용률 (추가 모니터링)
resource "aws_cloudwatch_metric_alarm" "rds1_cpu" {
  alarm_name          = "${var.project_name}-rds1-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300  # 5분
  statistic           = "Average"
  threshold           = 80  # 80% 이상
  alarm_description   = "RDS1 CPU utilization is high"
  
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = var.rds1_instance_id
  }

  tags = {
    Name = "${var.project_name}-rds1-cpu-alarm"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds2_cpu" {
  alarm_name          = "${var.project_name}-rds2-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300  # 5분
  statistic           = "Average"
  threshold           = 80  # 80% 이상
  alarm_description   = "RDS2 CPU utilization is high"
  
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = var.rds2_instance_id
  }

  tags = {
    Name = "${var.project_name}-rds2-cpu-alarm"
  }
}

# CloudWatch 알람 - RDS 연결 수 (추가 모니터링)
resource "aws_cloudwatch_metric_alarm" "rds1_connections" {
  alarm_name          = "${var.project_name}-rds1-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300  # 5분
  statistic           = "Average"
  threshold           = 80  # 80개 이상
  alarm_description   = "RDS1 database connections are high"
  
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = var.rds1_instance_id
  }

  tags = {
    Name = "${var.project_name}-rds1-connections-alarm"
  }
}

# CloudWatch Dashboard (실시간 모니터링 대시보드)
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x    = 0
        y    = 0
        width = 12
        height = 6
        properties = {
          metrics = [
            ["DBMigration/Failover", "DBHealthStatus", { stat = "Average", label = "EC2 DB1", color = "#1f77b4" }],
            [".", ".", { stat = "Average", label = "RDS1", color = "#ff7f0e" }],
            [".", ".", { stat = "Average", label = "RDS2", color = "#2ca02c" }]
          ]
          period = 60
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "DB Health Status (Real-time)"
          yAxis = {
            left = {
              min = 0
              max = 1
            }
          }
        }
      },
      {
        type = "metric"
        x    = 12
        y    = 0
        width = 12
        height = 6
        properties = {
          metrics = [
            ["DBMigration/Failover", "ReplicationLag", { stat = "Average", color = "#d62728" }]
          ]
          period = 60
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "Replication Lag (seconds)"
          yAxis = {
            left = {
              min = 0
            }
          }
        }
      },
      {
        type = "metric"
        x    = 0
        y    = 6
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds1_instance_id],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds2_instance_id]
          ]
          period = 300
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "RDS CPU Utilization (%)"
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
        }
      },
      {
        type = "metric"
        x    = 12
        y    = 6
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds1_instance_id],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds2_instance_id]
          ]
          period = 300
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "RDS Database Connections"
          yAxis = {
            left = {
              min = 0
            }
          }
        }
      }
    ]
  })
}
