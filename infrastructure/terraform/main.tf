terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC 및 네트워크
module "vpc" {
  source = "./modules/vpc"
  
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
}

# ALB (Public Subnet)
module "alb" {
  source = "./modules/alb"
  
  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = [module.vpc.public_subnet_az_a_id, module.vpc.public_subnet_az_b_id]
  
  web_instance_ids = [
    module.ec2_onprem.instance_ids["web1"],
    module.ec2_cloud.instance_ids["web2"]
  ]
}

# EC2 인스턴스 (온프레미스 가정 - AZ-a, Private Subnet)
module "ec2_onprem" {
  source = "./modules/ec2"
  
  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = var.vpc_cidr
  subnet_id         = module.vpc.private_subnet_az_a_id
  availability_zone = var.availability_zones[0]
  
  alb_security_group_ids = [module.alb.alb_security_group_id]
  
  # 4개 VM을 AMI로 가져온 후 EC2로 배포
  instances = {
    web1 = {
      ami           = var.web_ami_id
      instance_type = "t3.micro"
      name          = "web1"
    }
    was1 = {
      ami           = var.was_ami_id
      instance_type = "t3.small"
      name          = "was1"
    }
    proxysql1 = {
      ami           = var.proxysql_ami_id
      instance_type = "t3.small"
      name          = "proxysql1"
    }
    db1 = {
      ami           = var.mysql_ami_id
      instance_type = "t3.medium"
      name          = "db1"
    }
  }
}

# EC2 인스턴스 (클라우드 전환용 - AZ-b, Private Subnet)
module "ec2_cloud" {
  source = "./modules/ec2"
  
  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = var.vpc_cidr
  subnet_id         = module.vpc.private_subnet_az_b_id
  availability_zone = var.availability_zones[1]
  
  alb_security_group_ids = [module.alb.alb_security_group_id]
  
  instances = {
    web2 = {
      ami           = var.web_ami_id
      instance_type = "t3.micro"
      name          = "web2"
    }
    was2 = {
      ami           = var.was_ami_id
      instance_type = "t3.small"
      name          = "was2"
    }
    proxysql2 = {
      ami           = var.proxysql_ami_id
      instance_type = "t3.small"
      name          = "proxysql2"
    }
  }
}

# RDS 인스턴스
module "rds" {
  source = "./modules/rds"
  
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  
  # RDS1 (AZ-b, Private Subnet)
  rds1_subnet_ids = [module.vpc.private_subnet_az_b_id, module.vpc.private_subnet_az_c_id]
  rds1_az         = var.availability_zones[1]
  
  # RDS2 (AZ-c, Private Subnet)
  rds2_subnet_ids = [module.vpc.private_subnet_az_b_id, module.vpc.private_subnet_az_c_id]
  rds2_az         = var.availability_zones[2]
  
  db_username = var.db_username
  db_password = var.db_password
}

# NLB (ProxySQL 앞단, Private Subnet)
module "nlb" {
  source = "./modules/nlb"
  
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = [module.vpc.private_subnet_az_a_id, module.vpc.private_subnet_az_b_id]
  
  proxysql_instances = [
    module.ec2_onprem.instance_ids["proxysql1"],
    module.ec2_cloud.instance_ids["proxysql2"]
  ]
}

# DynamoDB (상태 관리)
module "dynamodb" {
  source = "./modules/dynamodb"
  
  project_name = var.project_name
}

# Lambda 함수
module "lambda" {
  source = "./modules/lambda"
  
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = [module.vpc.private_subnet_az_a_id, module.vpc.private_subnet_az_b_id]
  
  dynamodb_table_name = module.dynamodb.state_table_name
  sns_topic_arn       = module.sns.topic_arn
  
  # DB 엔드포인트
  ec2_db1_endpoint = module.ec2_onprem.private_ips["db1"]
  rds1_endpoint    = module.rds.rds1_endpoint
  rds2_endpoint    = module.rds.rds2_endpoint
  
  # ProxySQL 엔드포인트
  proxysql_endpoints = [
    module.ec2_onprem.private_ips["proxysql1"],
    module.ec2_cloud.private_ips["proxysql2"]
  ]
  
  # DB 비밀번호
  db_password   = var.db_password
  repl_password = var.repl_password
  
  # DMS Task ARN
  dms_task_arn               = module.dms.db1_to_rds1_task_arn
  rds1_to_rds2_dms_task_arn  = module.dms.rds1_to_rds2_task_arn
  rds1_to_db1_dms_task_arn   = module.dms.rds1_to_db1_task_arn
  rds2_to_rds1_dms_task_arn  = module.dms.rds2_to_rds1_task_arn
}

# CloudWatch 알람
module "cloudwatch" {
  source = "./modules/cloudwatch"
  
  project_name = var.project_name
  
  # Lambda 함수 ARN
  health_monitor_lambda_arn    = module.lambda.health_monitor_arn
  failover_controller_lambda_arn = module.lambda.failover_controller_arn
  
  # DB 인스턴스 ID
  ec2_db1_instance_id = module.ec2_onprem.instance_ids["db1"]
  rds1_instance_id    = module.rds.rds1_id
  rds2_instance_id    = module.rds.rds2_id
  
  sns_topic_arn = module.sns.topic_arn
}

# SNS (알림)
module "sns" {
  source = "./modules/sns"
  
  project_name = var.project_name
  email        = var.notification_email
}

# Route53 (도메인 설정 - 선택사항)
module "route53" {
  count  = var.enable_domain ? 1 : 0
  source = "./modules/route53"
  
  project_name = var.project_name
  domain_name  = var.domain_name
  subdomain    = var.subdomain
  alb_dns_name = module.alb.alb_dns_name
  alb_zone_id  = module.alb.alb_zone_id
}

# DMS (DB1 → RDS1 복제)
module "dms" {
  source = "./modules/dms"
  
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = [module.vpc.private_subnet_az_b_id, module.vpc.private_subnet_az_c_id]
  
  source_endpoint      = module.ec2_onprem.private_ips["db1"]
  target_endpoint      = module.rds.rds1_endpoint
  target_rds2_endpoint = module.rds.rds2_endpoint
  
  db_username = var.db_username
  db_password = var.db_password
  
  sns_topic_arn = module.sns.topic_arn
  
  # DMS Chain Starter Lambda ARN (SNS 구독용)
  dms_chain_starter_lambda_arn = module.lambda.dms_chain_starter_arn
}
