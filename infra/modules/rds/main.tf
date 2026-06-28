# ── Security Group ───────────────────────────────────────────────────────────
# Controls who can connect to RDS — only EKS worker nodes on port 5432
resource "aws_security_group" "rds" {
  name   = "${var.cluster_name}-rds-sg"  # e.g. "snapdf-dev-rds-sg"
  vpc_id = var.vpc_id                     # must belong to a specific VPC

  ingress {
    description     = "PostgreSQL from EKS nodes only"
    from_port       = 5432                          # PostgreSQL port
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]  # only allow traffic from EKS worker nodes
  }

  egress {
    from_port   = 0             # all ports
    to_port     = 0
    protocol    = "-1"          # all protocols
    cidr_blocks = ["0.0.0.0/0"] # RDS can send responses back out
  }

  tags = {
    Name        = "${var.cluster_name}-rds-sg"
    Environment = var.env_name
    ManagedBy   = "terragrunt"
  }
}

# ── RDS Instance ─────────────────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier        = "${var.cluster_name}-rds"  # name shown in AWS console e.g. "snapdf-dev-rds"
  engine            = "postgres"                  # PostgreSQL engine
  engine_version    = "16"                        # latest stable PostgreSQL version
  instance_class    = "db.t3.micro"              # cheapest instance — ~$15/month, destroy when not working
  allocated_storage = 20                          # 20 GB disk — minimum allowed by AWS

  db_name  = var.db_name      # database name inside PostgreSQL e.g. "snapdf"
  username = var.db_username  # master username e.g. "dbadmin"

  manage_master_user_password = true  # AWS generates password + stores it in Secrets Manager automatically

  db_subnet_group_name   = var.database_subnet_group_name  # which subnets to deploy into — from vpc module
  vpc_security_group_ids = [aws_security_group.rds.id]     # attach the security group above

  multi_az               = false  # single AZ — saves cost, fine for interview project
  publicly_accessible    = false  # never reachable from the internet
  skip_final_snapshot    = true   # allows terraform destroy without requiring a backup snapshot first
  deletion_protection    = false  # allows terraform destroy
  backup_retention_period = 0     # no automated backups — saves cost

  tags = {
    Environment = var.env_name
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}
