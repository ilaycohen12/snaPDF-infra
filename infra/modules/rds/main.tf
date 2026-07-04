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

# ── Keep the app-facing secret in sync with the real master password ────────
# manage_master_user_password generates a brand-new random password every time
# this instance is created (even a same-config recreate) and stores it in its
# own hidden, AWS-managed secret. ESO/postgres_exporter don't read that one
# directly though — they read a separate "consolidated" secret (bundling
# host+username+password) that was originally created by hand and, until now,
# had to be manually rebuilt after every RDS recreate (Bug 29 on 02/07/2026,
# recurred on both dev and prod during the 04/07/2026 full-VPC rebuild).
# This only ever writes a new *version* onto the existing secret (read via
# `data`, never created/imported here) — so it works with the secret exactly
# as it's always existed, no state-ownership migration needed.
data "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_db_instance.main.master_user_secret[0].secret_arn
}

data "aws_secretsmanager_secret" "consolidated" {
  name = var.env_name == "prod" ? "snapdf-prod/db-credentials" : "snapdf/db-credentials"
}

resource "aws_secretsmanager_secret_version" "consolidated" {
  secret_id = data.aws_secretsmanager_secret.consolidated.id
  secret_string = jsonencode({
    username = var.db_username
    host     = aws_db_instance.main.address
    password = jsondecode(data.aws_secretsmanager_secret_version.master.secret_string).password
  })
}
