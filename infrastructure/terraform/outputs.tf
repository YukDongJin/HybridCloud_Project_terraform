output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "ALB DNS 이름 (외부 접속용)"
  value       = module.alb.alb_dns_name
}

output "nlb_dns_name" {
  description = "NLB DNS 이름 (WAS에서 ProxySQL 접속용)"
  value       = module.nlb.dns_name
}

output "ec2_onprem_instances" {
  description = "온프레미스 가정 EC2 인스턴스 정보"
  value = {
    web1      = module.ec2_onprem.instance_ids["web1"]
    was1      = module.ec2_onprem.instance_ids["was1"]
    proxysql1 = module.ec2_onprem.instance_ids["proxysql1"]
    db1       = module.ec2_onprem.instance_ids["db1"]
  }
}

output "ec2_cloud_instances" {
  description = "클라우드 전환용 EC2 인스턴스 정보"
  value = {
    web2      = module.ec2_cloud.instance_ids["web2"]
    was2      = module.ec2_cloud.instance_ids["was2"]
    proxysql2 = module.ec2_cloud.instance_ids["proxysql2"]
  }
}

output "rds1_endpoint" {
  description = "RDS1 엔드포인트"
  value       = module.rds.rds1_endpoint
}

output "rds2_endpoint" {
  description = "RDS2 엔드포인트"
  value       = module.rds.rds2_endpoint
}

output "dynamodb_state_table" {
  description = "DynamoDB 상태 테이블 이름"
  value       = module.dynamodb.state_table_name
}

output "sns_topic_arn" {
  description = "SNS 토픽 ARN"
  value       = module.sns.topic_arn
}
