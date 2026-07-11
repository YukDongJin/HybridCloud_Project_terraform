resource "aws_lb" "proxysql" {
  name               = "${var.project_name}-nlb"
  internal           = true  # Private Subnet에서만 접근
  load_balancer_type = "network"
  subnets            = var.subnet_ids

  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-nlb"
  }
}

resource "aws_lb_target_group" "proxysql" {
  name     = "${var.project_name}-proxysql-tg"
  port     = 6033
  protocol = "TCP"
  vpc_id   = var.vpc_id

  deregistration_delay = 30
  
  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = 6033
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name = "${var.project_name}-proxysql-tg"
  }
}

resource "aws_lb_target_group_attachment" "proxysql" {
  count            = length(var.proxysql_instances)
  target_group_arn = aws_lb_target_group.proxysql.arn
  target_id        = var.proxysql_instances[count.index]
  port             = 6033
}

resource "aws_lb_listener" "proxysql" {
  load_balancer_arn = aws_lb.proxysql.arn
  port              = 6033
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxysql.arn
  }
}
