resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.rds1_subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS instances"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# RDS Parameter Group for DMS (binlog_format = ROW)
resource "aws_db_parameter_group" "dms" {
  name   = "${var.project_name}-mysql-dms"
  family = "mysql8.0"

  parameter {
    name  = "binlog_format"
    value = "ROW"
  }

  tags = {
    Name = "${var.project_name}-mysql-dms-params"
  }
}

# RDS1 (AZ-b)
resource "aws_db_instance" "rds1" {
  identifier             = "${var.project_name}-rds1"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.medium"
  allocated_storage      = 20
  storage_type           = "gp3"
  
  # db_name을 제거하여 깡통으로 생성 (DMS가 toydb 생성)
  # db_name  = "toydb"
  username = var.db_username
  password = var.db_password
  
  # DMS용 파라미터 그룹 (binlog_format = ROW)
  parameter_group_name   = aws_db_parameter_group.dms.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = var.rds1_az
  
  backup_retention_period = 7
  skip_final_snapshot     = true
  apply_immediately       = true
  
  # 복제 설정
  backup_window      = "03:00-04:00"
  maintenance_window = "mon:04:00-mon:05:00"

  tags = {
    Name = "${var.project_name}-rds1"
    Role = "slave"
  }
}

# RDS2 (AZ 자동 선택 - 하드코딩 제거)
resource "aws_db_instance" "rds2" {
  identifier             = "${var.project_name}-rds2"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.medium"
  allocated_storage      = 20
  storage_type           = "gp3"
  
  # db_name을 제거하여 깡통으로 생성 (RDS1 복제로 toydb 생성)
  # db_name  = "toydb"
  username = var.db_username
  password = var.db_password
  
  # DMS용 파라미터 그룹 (binlog_format = ROW)
  parameter_group_name   = aws_db_parameter_group.dms.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = var.rds2_az
  
  backup_retention_period = 7
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = {
    Name = "${var.project_name}-rds2"
    Role = "standby"
  }
}
