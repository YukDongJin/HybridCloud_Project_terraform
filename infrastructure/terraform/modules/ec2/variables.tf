variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
}

variable "subnet_id" {
  description = "서브넷 ID"
  type        = string
}

variable "availability_zone" {
  description = "가용 영역"
  type        = string
}

variable "instances" {
  description = "생성할 인스턴스 맵"
  type = map(object({
    ami           = string
    instance_type = string
    name          = string
  }))
}

variable "alb_security_group_ids" {
  description = "ALB Security Group IDs"
  type        = list(string)
  default     = []
}
