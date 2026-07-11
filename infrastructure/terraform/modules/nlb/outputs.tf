output "dns_name" {
  description = "NLB DNS 이름"
  value       = aws_lb.proxysql.dns_name
}

output "arn" {
  value = aws_lb.proxysql.arn
}
