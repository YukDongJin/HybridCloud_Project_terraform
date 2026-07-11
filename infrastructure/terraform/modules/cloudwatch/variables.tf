variable "project_name" {
  type = string
}

variable "health_monitor_lambda_arn" {
  type = string
}

variable "failover_controller_lambda_arn" {
  type = string
}

variable "ec2_db1_instance_id" {
  type = string
}

variable "rds1_instance_id" {
  type = string
}

variable "rds2_instance_id" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}
