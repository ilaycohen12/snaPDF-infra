resource "aws_sqs_queue" "signed" {
  for_each = toset(var.app_namespaces)

  name                       = "snapdf-${each.value}-signed"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600

  tags = {
    Environment = var.env_name
    Queue       = "signed"
    ManagedBy   = "terragrunt"
  }
}

resource "aws_sqs_queue" "free" {
  for_each = toset(var.app_namespaces)

  name                       = "snapdf-${each.value}-free"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600

  tags = {
    Environment = var.env_name
    Queue       = "free"
    ManagedBy   = "terragrunt"
  }
}
