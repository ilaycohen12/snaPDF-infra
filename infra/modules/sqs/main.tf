resource "aws_sqs_queue" "signed" {
  name                       = "${var.cluster_name}-signed" # e.g. "snapdf-dev-signed"
  visibility_timeout_seconds = 60   # message hidden for 60s after worker picks it up — if worker crashes, message reappears for retry
  message_retention_seconds  = 3600 # delete unprocessed messages after 1 hour

  tags = {
    Environment = var.env_name
    Queue       = "signed"
    ManagedBy   = "terragrunt"
  }
}

resource "aws_sqs_queue" "free" {
  name                       = "${var.cluster_name}-free" # e.g. "snapdf-dev-free"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600

  tags = {
    Environment = var.env_name
    Queue       = "free"
    ManagedBy   = "terragrunt"
  }
}
