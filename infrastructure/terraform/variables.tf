variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "db-migration-failover"
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "가용 영역 리스트"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
}

# VM에서 생성한 AMI ID (VM Import 후 입력)
variable "web_ami_id" {
  description = "Web(Nginx) AMI ID"
  type        = string
  default     = ""  # VM Import 후 업데이트
}

variable "was_ami_id" {
  description = "WAS(Flask) AMI ID"
  type        = string
  default     = ""  # VM Import 후 업데이트
}

variable "proxysql_ami_id" {
  description = "ProxySQL AMI ID"
  type        = string
  default     = ""  # VM Import 후 업데이트
}

variable "mysql_ami_id" {
  description = "MySQL(DB1) AMI ID"
  type        = string
  default     = ""  # VM Import 후 업데이트
}

variable "db_username" {
  description = "데이터베이스 사용자 이름"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "db_password" {
  description = "데이터베이스 비밀번호"
  type        = string
  sensitive   = true
}

variable "notification_email" {
  description = "알림 수신 이메일"
  type        = string
}

variable "domain_name" {
  description = "도메인 이름 (예: youk.cloud)"
  type        = string
  default     = ""
}

variable "subdomain" {
  description = "서브도메인 (예: failover)"
  type        = string
  default     = "failover"
}

variable "enable_domain" {
  description = "도메인 사용 여부"
  type        = bool
  default     = false
}

variable "repl_password" {
  description = "MySQL 복제 사용자 비밀번호"
  type        = string
  default     = "repl_password123"
  sensitive   = true
}
