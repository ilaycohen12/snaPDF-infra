output "signed_queue_urls" {
  description = "Signed queue URLs, keyed by namespace — used by the signed worker to receive and delete messages"
  value       = { for ns, q in aws_sqs_queue.signed : ns => q.url }
}

output "signed_queue_arns" {
  description = "Signed queue ARNs, keyed by namespace — used by IAM to write permission policies"
  value       = { for ns, q in aws_sqs_queue.signed : ns => q.arn }
}

output "free_queue_urls" {
  description = "Free queue URLs, keyed by namespace — used by the free worker to receive and delete messages"
  value       = { for ns, q in aws_sqs_queue.free : ns => q.url }
}

output "free_queue_arns" {
  description = "Free queue ARNs, keyed by namespace — used by IAM to write permission policies"
  value       = { for ns, q in aws_sqs_queue.free : ns => q.arn }
}
