resource "aws_cloudwatch_log_group" "sandbox" {
  name              = "/ecs/bashforge-sandbox"
  retention_in_days = 7

  tags = { Name = "bashforge-sandbox-logs" }
}
