variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "source_endpoint" {
  type = string
}

variable "target_endpoint" {
  type = string
}

variable "target_rds2_endpoint" {
  type = string
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "sns_topic_arn" {
  type        = string
  description = "SNS Topic ARN for DMS event notifications"
}

variable "dms_chain_starter_lambda_arn" {
  type        = string
  description = "Lambda function ARN for DMS chain starter"
}
