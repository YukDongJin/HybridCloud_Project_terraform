output "instance_ids" {
  description = "인스턴스 ID 맵"
  value       = { for k, v in aws_instance.instances : k => v.id }
}

output "private_ips" {
  description = "인스턴스 Private IP 맵"
  value       = { for k, v in aws_instance.instances : k => v.private_ip }
}

output "public_ips" {
  description = "인스턴스 Public IP 맵"
  value       = { for k, v in aws_instance.instances : k => v.public_ip }
}
