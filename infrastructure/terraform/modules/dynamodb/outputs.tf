output "state_table_name" {
  value = aws_dynamodb_table.state.name
}

output "events_table_name" {
  value = aws_dynamodb_table.events.name
}
