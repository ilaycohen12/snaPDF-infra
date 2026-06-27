variable "env_name" {
  description = "Environment name (dev or prod) — used in resource names and tags"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used to name RDS resources e.g. projectview-dev-rds"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — needed to create the RDS security group in the right VPC"
  type        = string
}

variable "database_subnet_group_name" {
  description = "RDS subnet group name — from the vpc module, tells RDS which subnets to deploy into"
  type        = string
}

variable "node_security_group_id" {
  description = "Security group ID of the EKS worker nodes — RDS only allows port 5432 from this group"
  type        = string
}

variable "db_name" {
  description = "Name of the database inside PostgreSQL"
  type        = string
  default     = "projectview"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "dbadmin"
}
