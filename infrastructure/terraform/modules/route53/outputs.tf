output "domain_name" {
  value = "${var.subdomain}.${var.domain_name}"
}

output "certificate_arn" {
  value = aws_acm_certificate.main.arn
}

output "nameservers" {
  value = data.aws_route53_zone.main.name_servers
}
