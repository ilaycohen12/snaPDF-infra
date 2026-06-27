output "db_endpoint" {
  description = "RDS connection endpoint — used by the Flask app to connect to the database"
  value       = aws_db_instance.main.address
}

output "db_name" {
  description = "Database name inside PostgreSQL — used by the Flask app connection string"
  value       = aws_db_instance.main.db_name
}

output "db_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB password — used by ESO to sync it into the cluster"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
