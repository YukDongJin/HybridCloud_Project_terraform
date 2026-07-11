variable "project_name" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "subdomain" {
  type    = string
  default = "failover"
}

variable "alb_dns_name" {
  type = string
}

variable "alb_zone_id" {
  type = string
}
