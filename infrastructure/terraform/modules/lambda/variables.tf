variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "dynamodb_table_name" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}

variable "ec2_db1_endpoint" {
  type = string
}

variable "rds1_endpoint" {
  type = string
}

variable "rds2_endpoint" {
  type = string
}

variable "proxysql_endpoints" {
  type = list(string)
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "repl_password" {
  type      = string
  sensitive = true
}

variable "dms_task_arn" {
  type = string
}

variable "rds1_to_rds2_dms_task_arn" {
  type = string
}

variable "rds1_to_db1_dms_task_arn" {
  type = string
}

variable "rds2_to_rds1_dms_task_arn" {
  type = string
}