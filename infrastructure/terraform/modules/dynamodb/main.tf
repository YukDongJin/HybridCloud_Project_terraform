resource "aws_dynamodb_table" "state" {
  name           = "${var.project_name}-state"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "pk"
  range_key      = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-state-table"
  }
}

resource "aws_dynamodb_table" "events" {
  name           = "${var.project_name}-events"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "pk"
  range_key      = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-events-table"
  }
}
