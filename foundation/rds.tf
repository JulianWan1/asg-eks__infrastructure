# ===========================================================================
# RDS — PostgreSQL in the private subnets
# ===========================================================================
# This is the database the URL-shortener talks to. It mirrors what
# docker-compose.yml runs locally: Postgres 16, database "shortener",
# user "shortener" — so the app code works identically in both places.
# The only thing that changes is DATABASE_URL.
#
# The app self-migrates on boot (CREATE TABLE IF NOT EXISTS in db.ts),
# so a brand-new, empty RDS instance works with zero manual steps.
# That's the whole point: `make down` destroys this, `make up` creates
# a fresh one, and the first app instance to start builds the schema.


# ===========================================================================
# Password — generated once, stored in Terraform state
# ===========================================================================
# For a nightly-destroy dev lab, this is the right level of ceremony.
# In production you'd use AWS Secrets Manager or IAM database auth instead.
resource "random_password" "db" {
  length  = 24
  special = false # keeps the DATABASE_URL clean — no URL-encoding needed
}


# ===========================================================================
# Subnet group — tells RDS which subnets it can use
# ===========================================================================
# Even though we're single-AZ, RDS requires a subnet group with at least
# two subnets in different AZs. AWS needs the option to fail over even
# if we haven't enabled multi-AZ — it's a requirement of the service.
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project}-db-subnets" }
}


# ===========================================================================
# The RDS instance itself
# ===========================================================================
resource "aws_db_instance" "main" {
  identifier = "${var.project}-db"

  # Engine — match the local docker-compose Postgres version
  engine         = "postgres"
  engine_version = "16"

  # Size — smallest available, sufficient for a learning workload
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  # Credentials — match the local dev names so the app code is identical
  db_name  = "shortener"
  username = "shortener"
  password = random_password.db.result

  # Networking — private subnets only, locked to the db security group
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  port                   = 5432

  # Availability — single-AZ to save cost. The lab can tolerate downtime;
  # a production setup would set this to true for automatic failover.
  multi_az = false

  # Backups — off. This DB is disposable; there's nothing to recover.
  backup_retention_period = 0
  skip_final_snapshot     = true

  # Apply changes immediately rather than waiting for a maintenance window.
  # In production you'd leave this false so changes roll out during off-hours.
  apply_immediately = true

  tags = { Name = "${var.project}-db" }
}


# ===========================================================================
# Outputs
# ===========================================================================

# The full connection string the app needs. Marked sensitive because it
# contains the password. The launch template (Step 6) will reference this
# to set the DATABASE_URL environment variable on each EC2 instance.
output "database_url" {
  description = "Full DATABASE_URL for the app (contains password)"
  value       = "postgres://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}?sslmode=no-verify"
  sensitive   = true
}

# Useful for debugging — you can see the endpoint without exposing the password
output "db_endpoint" {
  description = "RDS endpoint (hostname:port)"
  value       = aws_db_instance.main.endpoint
}
