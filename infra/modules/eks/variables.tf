variable "env_name" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — e.g. snapdf-dev"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "vpc_id" {
  description = "ID of the VPC — from the vpc module output"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs where worker nodes will run — from the vpc module output"
  type        = list(string)
}
