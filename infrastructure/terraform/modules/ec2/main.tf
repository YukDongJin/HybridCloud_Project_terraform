# IAM Role for SSM
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-${var.availability_zone}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.availability_zone}-ec2-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-${var.availability_zone}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_security_group" "instances" {
  name        = "${var.project_name}-${var.availability_zone}-sg"
  description = "Security group for EC2 instances"
  vpc_id      = var.vpc_id

  # HTTP (Nginx) - ALB에서만 접근
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = var.alb_security_group_ids
    description     = "HTTP from ALB"
  }

  # Flask (WAS) - VPC 내부에서만 접근
  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Flask from VPC"
  }

  # MySQL - VPC 내부에서만 접근
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "MySQL from VPC"
  }

  # ProxySQL - VPC 내부에서만 접근
  ingress {
    from_port   = 6033
    to_port     = 6033
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "ProxySQL from VPC"
  }

  # ProxySQL Admin - VPC 내부에서만 접근
  ingress {
    from_port   = 6032
    to_port     = 6032
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "ProxySQL Admin from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.availability_zone}-sg"
  }
}

resource "aws_instance" "instances" {
  for_each = var.instances

  ami                    = each.value.ami
  instance_type          = each.value.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instances.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  
  tags = {
    Name = "${var.project_name}-${each.value.name}"
    Role = each.value.name
  }
}
