# ── Security Group ───────────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name   = "${var.cluster_name}-rds-sg"
  vpc_id = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-rds-sg"
    Environment = var.env_name
    ManagedBy   = "terragrunt"
  }
}

# ── RDS Instance ─────────────────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier        = "${var.cluster_name}-rds"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = var.db_name
  username = var.db_username

  manage_master_user_password = true

  db_subnet_group_name   = var.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az                = false
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0

  tags = {
    Environment = var.env_name
    Project     = "snapdf"
    ManagedBy   = "terragrunt"
  }
}

# ── Keep the app-facing secret in sync with the real master password ────────
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
