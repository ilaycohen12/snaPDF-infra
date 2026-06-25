output "vpc_id" {
  description = "ID of the VPC — used by EKS, RDS, and security groups"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets — used by the ALB Ingress Controller"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the private subnets — used by EKS for worker nodes"
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "IDs of the database subnets — used by RDS"
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "Name of the RDS subnet group — passed directly to the RDS instance"
  value       = module.vpc.database_subnet_group_name
}
