variable "env_name" {
  description = "Environment name (dev or prod) — used in resource names and tags"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the entire VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across — replaces hand-maintained azs/*_subnet_cidrs lists. AZs are discovered dynamically; each tier's subnet CIDRs are computed from vpc_cidr, not hardcoded."
  type        = number
  default     = 2
}
