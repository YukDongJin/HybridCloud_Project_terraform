# DMS VPC Role (DMS가 VPC 리소스에 접근하기 위한 IAM Role)
resource "aws_iam_role" "dms_vpc_role" {
  name = "dms-vpc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "dms.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_vpc_role" {
  role       = aws_iam_role.dms_vpc_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

# DMS CloudWatch Logs Role (DMS가 CloudWatch에 로그를 쓰기 위한 IAM Role)
resource "aws_iam_role" "dms_cloudwatch_logs_role" {
  name = "dms-cloudwatch-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "dms.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_cloudwatch_logs_role" {
  role       = aws_iam_role.dms_cloudwatch_logs_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}

# DMS Replication Subnet Group
resource "aws_dms_replication_subnet_group" "main" {
  replication_subnet_group_id          = "${var.project_name}-dms-subnet-group"
  replication_subnet_group_description = "DMS replication subnet group"
  subnet_ids                           = var.subnet_ids

  tags = {
    Name = "${var.project_name}-dms-subnet-group"
  }

  depends_on = [aws_iam_role_policy_attachment.dms_vpc_role]
}

# DMS Replication Instance
resource "aws_dms_replication_instance" "main" {
  replication_instance_id   = "${var.project_name}-dms-instance"
  replication_instance_class = "dms.t3.medium"
  allocated_storage          = 20
  
  replication_subnet_group_id = aws_dms_replication_subnet_group.main.id
  publicly_accessible         = false

  tags = {
    Name = "${var.project_name}-dms-instance"
  }
}

# ========================================
# 정방향 복제용 Endpoints
# ========================================

# Source Endpoint (DB1 - EC2) - 정방향용
resource "aws_dms_endpoint" "source_db1" {
  endpoint_id   = "${var.project_name}-source-db1"
  endpoint_type = "source"
  engine_name   = "mysql"
  
  server_name = split(":", var.source_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-source-db1-endpoint"
  }
}

# Target Endpoint (RDS1) - 정방향용
resource "aws_dms_endpoint" "target_rds1" {
  endpoint_id   = "${var.project_name}-target-rds1"
  endpoint_type = "target"
  engine_name   = "mysql"
  
  server_name = split(":", var.target_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-target-rds1-endpoint"
  }
}

# Source Endpoint (RDS1) - RDS1→RDS2 정방향용
resource "aws_dms_endpoint" "source_rds1" {
  endpoint_id   = "${var.project_name}-source-rds1"
  endpoint_type = "source"
  engine_name   = "mysql"
  
  server_name = split(":", var.target_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-source-rds1-endpoint"
  }
}

# Target Endpoint (RDS2) - RDS1→RDS2 정방향용
resource "aws_dms_endpoint" "target_rds2" {
  endpoint_id   = "${var.project_name}-target-rds2"
  endpoint_type = "target"
  engine_name   = "mysql"
  
  server_name = split(":", var.target_rds2_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-target-rds2-endpoint"
  }
}

# ========================================
# 역방향 복제용 Endpoints (Rollback용)
# ========================================

# Target Endpoint (DB1) - 역방향용 (RDS1→DB1)
resource "aws_dms_endpoint" "target_db1_reverse" {
  endpoint_id   = "${var.project_name}-target-db1-reverse"
  endpoint_type = "target"
  engine_name   = "mysql"
  
  server_name = split(":", var.source_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  extra_connection_attributes = "initstmt=SET GLOBAL local_infile=1"
 
  tags = {
    Name = "${var.project_name}-target-db1-reverse-endpoint"
  }
}

# Source Endpoint (RDS1) - 역방향용 (RDS1→DB1)
resource "aws_dms_endpoint" "source_rds1_reverse" {
  endpoint_id   = "${var.project_name}-source-rds1-reverse"
  endpoint_type = "source"
  engine_name   = "mysql"
  
  server_name = split(":", var.target_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-source-rds1-reverse-endpoint"
  }
}

# Source Endpoint (RDS2) - 역방향용 (RDS2→RDS1)
resource "aws_dms_endpoint" "source_rds2_reverse" {
  endpoint_id   = "${var.project_name}-source-rds2-reverse"
  endpoint_type = "source"
  engine_name   = "mysql"
  
  server_name = split(":", var.target_rds2_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-source-rds2-reverse-endpoint"
  }
}

# Target Endpoint (RDS1) - 역방향용 (RDS2→RDS1)
resource "aws_dms_endpoint" "target_rds1_reverse" {
  endpoint_id   = "${var.project_name}-target-rds1-reverse"
  endpoint_type = "target"
  engine_name   = "mysql"
  
  server_name = split(":", var.target_endpoint)[0]
  port        = 3306
  username    = var.db_username
  password    = var.db_password

  tags = {
    Name = "${var.project_name}-target-rds1-reverse-endpoint"
  }
}

# ========================================
# 정방향 DMS Replication Tasks
# ========================================

# Task 1: DB1 → RDS1 (정방향)
resource "aws_dms_replication_task" "db1_to_rds1" {
  replication_task_id      = "${var.project_name}-db1-to-rds1"
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source_db1.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target_rds1.endpoint_arn
  
  start_replication_task = false
  
  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "1"
      object-locator = {
        schema-name = "%"
        table-name  = "%"
      }
      rule-action = "include"
    }]
  })
  
  replication_task_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        {
          Id       = "TRANSFORMATION"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "SOURCE_UNLOAD"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "TARGET_LOAD"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "SOURCE_CAPTURE"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "TARGET_APPLY"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        }
      ]
    }
  })

  tags = {
    Name = "${var.project_name}-db1-to-rds1-task"
  }
  
  depends_on = [
    aws_dms_replication_instance.main,
    aws_dms_endpoint.source_db1,
    aws_dms_endpoint.target_rds1,
    aws_iam_role_policy_attachment.dms_cloudwatch_logs_role
  ]
  
  # 모든 리소스 준비 후 Task 1 시작
  provisioner "local-exec" {
    command     = "Start-Sleep -Seconds 10; aws dms start-replication-task --replication-task-arn ${self.replication_task_arn} --start-replication-task-type start-replication"
    interpreter = ["PowerShell", "-Command"]
  }
}

# Task 2: RDS1 → RDS2 (정방향)
resource "aws_dms_replication_task" "rds1_to_rds2" {
  replication_task_id      = "${var.project_name}-rds1-to-rds2"
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source_rds1.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target_rds2.endpoint_arn
  
  start_replication_task = false
  
  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "1"
      object-locator = {
        schema-name = "%"
        table-name  = "%"
      }
      rule-action = "include"
    }]
  })
  
  replication_task_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        {
          Id       = "TRANSFORMATION"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "SOURCE_UNLOAD"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "TARGET_LOAD"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "SOURCE_CAPTURE"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "TARGET_APPLY"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        }
      ]
    }
  })

  tags = {
    Name = "${var.project_name}-rds1-to-rds2-task"
  }
  
  depends_on = [
    aws_dms_replication_instance.main,
    aws_dms_endpoint.source_rds1,
    aws_dms_endpoint.target_rds2,
    aws_iam_role_policy_attachment.dms_cloudwatch_logs_role
  ]
}

# ========================================
# 역방향 DMS Replication Tasks (Rollback용)
# ========================================

# Task 3: RDS1 → DB1 (역방향, Rollback용 CDC)
resource "aws_dms_replication_task" "rds1_to_db1" {
  replication_task_id      = "${var.project_name}-rds1-to-db1"
  migration_type           = "cdc"
  replication_instance_arn = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source_rds1_reverse.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target_db1_reverse.endpoint_arn
  
  start_replication_task = false
  
  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "1"
      object-locator = {
        schema-name = "%"
        table-name  = "%"
      }
      rule-action = "include"
    }]
  })
  
  replication_task_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        {
          Id       = "SOURCE_CAPTURE"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "TARGET_APPLY"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        }
      ]
    }
  })

  tags = {
    Name = "${var.project_name}-rds1-to-db1-rollback-task"
  }
  
  depends_on = [
    aws_dms_replication_instance.main,
    aws_dms_endpoint.source_rds1_reverse,
    aws_dms_endpoint.target_db1_reverse,
    aws_iam_role_policy_attachment.dms_cloudwatch_logs_role
  ]
}

# Task 4: RDS2 → RDS1 (역방향, Rollback용 CDC)
resource "aws_dms_replication_task" "rds2_to_rds1" {
  replication_task_id      = "${var.project_name}-rds2-to-rds1"
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source_rds2_reverse.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target_rds1_reverse.endpoint_arn
  
  start_replication_task = false
  
  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "1"
      object-locator = {
        schema-name = "%"
        table-name  = "%"
      }
      rule-action = "include"
    }]
  })
  
  replication_task_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        {
          Id       = "SOURCE_CAPTURE"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        },
        {
          Id       = "TARGET_APPLY"
          Severity = "LOGGER_SEVERITY_DEFAULT"
        }
      ]
    }
  })

  tags = {
    Name = "${var.project_name}-rds2-to-rds1-rollback-task"
  }
  
  depends_on = [
    aws_dms_replication_instance.main,
    aws_dms_endpoint.source_rds2_reverse,
    aws_dms_endpoint.target_rds1_reverse,
    aws_iam_role_policy_attachment.dms_cloudwatch_logs_role
  ]
}

# ========================================
# DMS Event Subscription
# ========================================

# DMS Event Subscription (SNS로 이벤트 전송)
resource "aws_dms_event_subscription" "replication_task_events" {
  name          = "${var.project_name}-dms-events"
  sns_topic_arn = var.sns_topic_arn
  
  source_type = "replication-task"
  source_ids  = [
    aws_dms_replication_task.db1_to_rds1.replication_task_id,
    aws_dms_replication_task.rds1_to_rds2.replication_task_id,
    aws_dms_replication_task.rds1_to_db1.replication_task_id,
    aws_dms_replication_task.rds2_to_rds1.replication_task_id
  ]
  
  event_categories = [
    "state change",
    "failure",
    "configuration change"
  ]
  
  enabled = true
  
  tags = {
    Name = "${var.project_name}-dms-event-subscription"
  }
}

# SNS Subscription - DMS 이벤트를 Lambda로 직접 전달
resource "aws_sns_topic_subscription" "dms_to_lambda" {
  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = var.dms_chain_starter_lambda_arn
}