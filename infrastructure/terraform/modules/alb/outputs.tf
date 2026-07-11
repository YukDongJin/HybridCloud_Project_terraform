output "alb_dns_name" {
  description = "ALB DNS 이름"
  value       = aws_lb.web.dns_name
}

output "alb_arn" {
  value = aws_lb.web.arn
}

output "alb_zone_id" {
  description = "ALB Zone ID (Route53용)"
  value       = aws_lb.web.zone_id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "target_group_arn" {
  value = aws_lb_target_group.web.arn
}
