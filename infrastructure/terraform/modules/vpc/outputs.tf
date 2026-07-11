output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_az_a_id" {
  description = "Public Subnet AZ-a ID"
  value       = aws_subnet.public_az_a.id
}

output "public_subnet_az_b_id" {
  description = "Public Subnet AZ-b ID"
  value       = aws_subnet.public_az_b.id
}

output "private_subnet_az_a_id" {
  description = "Private Subnet AZ-a ID"
  value       = aws_subnet.private_az_a.id
}

output "private_subnet_az_b_id" {
  description = "Private Subnet AZ-b ID"
  value       = aws_subnet.private_az_b.id
}

output "private_subnet_az_c_id" {
  description = "Private Subnet AZ-c ID"
  value       = aws_subnet.private_az_c.id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = aws_nat_gateway.main.id
}
