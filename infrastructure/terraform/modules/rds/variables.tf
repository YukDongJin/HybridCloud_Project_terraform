variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "rds1_subnet_ids" {
  type = list(string)
}

variable "rds1_az" {
  type = string
}

variable "rds2_subnet_ids" {
  type = list(string)
}

variable "rds2_az" {
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
