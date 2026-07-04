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

output "resource_id" {
  description = "RDS's own internal resource ID (distinct from the identifier) — changes every time a real new instance is created, even with the same identifier/config. Used to key one-off post-recreate jobs (e.g. recreating the snapdf_staging logical database) so they only re-run when actually needed."
  value       = aws_db_instance.main.resource_id
}
