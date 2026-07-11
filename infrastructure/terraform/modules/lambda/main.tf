# IAM Role for Lambda
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_custom" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query"
        ]
        Resource = "arn:aws:dynamodb:*:*:table/${var.dynamodb_table_name}"
      },
      {
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:ModifyDBInstance"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = var.sns_topic_arn
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "dms:StopReplicationTask",
          "dms:StartReplicationTask",
          "dms:DescribeReplicationTasks"
        ]
        Resource = "*"
      }
    ]
  })
}

# Security Group for Lambda
resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Security group for Lambda functions"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-lambda-sg"
  }
}

# Health Monitor Lambda (CloudWatch Alarm에서 호출)
resource "aws_lambda_function" "health_monitor" {
  filename      = "${path.root}/../../lambda/health_monitor.zip"
  function_name = "${var.project_name}-health-monitor"
  role          = aws_iam_role.lambda.arn
  handler       = "health_monitor.lambda_handler"
  runtime       = "python3.11"
  timeout       = 60

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DYNAMODB_TABLE    = var.dynamodb_table_name
      SNS_TOPIC_ARN     = var.sns_topic_arn
      EC2_DB1_ENDPOINT  = var.ec2_db1_endpoint
      RDS1_ENDPOINT     = var.rds1_endpoint
      RDS2_ENDPOINT     = var.rds2_endpoint
      DB_PASSWORD       = var.db_password
    }
  }
}

# Failover Controller Lambda
resource "aws_lambda_function" "failover_controller" {
  filename      = "${path.root}/../../lambda/failover_controller.zip"
  function_name = "${var.project_name}-failover-controller"
  role          = aws_iam_role.lambda.arn
  handler       = "failover_controller.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DYNAMODB_TABLE             = var.dynamodb_table_name
      SNS_TOPIC_ARN              = var.sns_topic_arn
      EC2_DB1_ENDPOINT           = var.ec2_db1_endpoint
      RDS1_ENDPOINT              = var.rds1_endpoint
      RDS2_ENDPOINT              = var.rds2_endpoint
      PROXYSQL_ENDPOINTS         = join(",", var.proxysql_endpoints)
      DB_PASSWORD                = var.db_password
      REPL_PASSWORD              = var.repl_password
      DMS_TASK_ARN               = var.dms_task_arn
      RDS1_TO_RDS2_DMS_TASK_ARN  = var.rds1_to_rds2_dms_task_arn
      RDS1_TO_DB1_DMS_TASK_ARN   = var.rds1_to_db1_dms_task_arn   # 롤백용
      RDS2_TO_RDS1_DMS_TASK_ARN  = var.rds2_to_rds1_dms_task_arn  # 롤백용
    }
  }
}

# CloudWatch Alarm에서 Lambda 호출 권한
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover_controller.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
}

# EventBridge 규칙 - Failover Controller Warm Start (5분마다)
resource "aws_cloudwatch_event_rule" "failover_controller_warmup" {
  name                = "${var.project_name}-failover-warmup"
  description         = "Keep failover controller warm by invoking every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "failover_controller_warmup" {
  rule      = aws_cloudwatch_event_rule.failover_controller_warmup.name
  target_id = "FailoverControllerWarmup"
  arn       = aws_lambda_function.failover_controller.arn
  
  input = jsonencode({
    "warmup" = true
  })
}

resource "aws_lambda_permission" "allow_eventbridge_warmup" {
  statement_id  = "AllowExecutionFromEventBridgeWarmup"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover_controller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.failover_controller_warmup.arn
}

# EventBridge 규칙 - Health Monitor를 1분마다 실행
resource "aws_cloudwatch_event_rule" "health_monitor_schedule" {
  name                = "${var.project_name}-health-monitor-schedule"
  description         = "Trigger health monitor every 1 minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "health_monitor" {
  rule      = aws_cloudwatch_event_rule.health_monitor_schedule.name
  target_id = "HealthMonitorLambda"
  arn       = aws_lambda_function.health_monitor.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_monitor_schedule.arn
}

# DMS Chain Starter Lambda (DB1→RDS1 완료 시 RDS1→RDS2 자동 시작)
resource "aws_lambda_function" "dms_chain_starter" {
  filename      = "${path.root}/../../lambda/dms_chain_starter.zip"
  function_name = "${var.project_name}-dms-chain-starter"
  role          = aws_iam_role.lambda.arn
  handler       = "dms_chain_starter.lambda_handler"
  runtime       = "python3.11"
  timeout       = 60

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      RDS1_TO_RDS2_DMS_TASK_ARN = var.rds1_to_rds2_dms_task_arn
      SNS_TOPIC_ARN             = var.sns_topic_arn
      DYNAMODB_TABLE            = var.dynamodb_table_name
    }
  }
}

# SNS에서 Lambda 직접 호출 권한
resource "aws_lambda_permission" "allow_sns_dms" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dms_chain_starter.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}

# EventBridge 규칙 - DMS Task 1 완료 체크 (1분마다)
resource "aws_cloudwatch_event_rule" "dms_task1_completion_check" {
  name                = "${var.project_name}-dms-task1-check"
  description         = "Check DMS Task 1 completion every 1 minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "dms_task1_check" {
  rule      = aws_cloudwatch_event_rule.dms_task1_completion_check.name
  target_id = "DMSTask1CompletionCheck"
  arn       = aws_lambda_function.dms_chain_starter.arn
  
  input = jsonencode({
    "source" = "eventbridge.schedule"
    "action" = "check_task1_completion"
  })
}

resource "aws_lambda_permission" "allow_eventbridge_dms_task1" {
  statement_id  = "AllowExecutionFromEventBridgeDMSTask1"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dms_chain_starter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dms_task1_completion_check.arn
}

# EventBridge 규칙 - DMS Task 2 완료 체크 (1분마다)
resource "aws_cloudwatch_event_rule" "dms_task2_completion_check" {
  name                = "${var.project_name}-dms-task2-check"
  description         = "Check DMS Task 2 completion every 1 minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "dms_task2_check" {
  rule      = aws_cloudwatch_event_rule.dms_task2_completion_check.name
  target_id = "DMSTask2CompletionCheck"
  arn       = aws_lambda_function.dms_chain_starter.arn
  
  input = jsonencode({
    "source" = "eventbridge.schedule"
    "action" = "check_task2_completion"
  })
}

resource "aws_lambda_permission" "allow_eventbridge_dms" {
  statement_id  = "AllowExecutionFromEventBridgeDMS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dms_chain_starter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dms_task2_completion_check.arn
}
