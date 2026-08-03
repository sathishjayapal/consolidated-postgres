terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# DigitalOcean PostgreSQL Database Cluster
resource "digitalocean_database_cluster" "postgres" {
  name       = var.database_name
  engine     = "pg"
  version    = "15"
  region     = var.region
  node_count = 1
  size       = "db-s-1vcpu-1gb"  # Small, cost-effective size

  tags = ["dev", "on-demand"]

  # IMPORTANT: No prevent_destroy - this allows you to destroy the database
  # when not coding to save money. Database costs ~$0.50/day when running.
  # Create with: ./prod-start.sh
  # Destroy with: ./prod-stop.sh (exports data first)
}

# Application databases within the cluster
resource "digitalocean_database_db" "eventstracker_db" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = "eventstracker_db"
}

resource "digitalocean_database_db" "runsapp_db" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = "runsapp_db"
}

resource "digitalocean_database_db" "runsai_db" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = "runsai_db"
}

# Database user for your application
resource "digitalocean_database_user" "app_user" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.db_username
}

# NOTE: Firewall rules
# If you need to restrict access to specific IPs, add a firewall rule here
# For development (allowing all IPs), leave this commented out
# Example:
# resource "digitalocean_database_firewall" "app_firewall" {
#   cluster_id = digitalocean_database_cluster.postgres.id
#   rule {
#     type  = "app"
#     value = "app_id"
#   }
# }
# To allow all IPs: don't specify any rules (current setup)

# Database password (random generated, outputted for first use)
resource "random_password" "db_password" {
  length  = 16
  special = true
}

# Store password in env/.env.prod for later use
output "database_password" {
  value       = random_password.db_password.result
  description = "Database password (generated once)"
  sensitive   = true
}

# Output connection details
output "database_host" {
  value       = digitalocean_database_cluster.postgres.host
  description = "PostgreSQL host"
  sensitive   = false
}

output "database_port" {
  value       = digitalocean_database_cluster.postgres.port
  description = "PostgreSQL port"
}

output "database_user" {
  value       = digitalocean_database_user.app_user.name
  description = "Database username"
}

output "eventstracker_db_name" {
  value       = digitalocean_database_db.eventstracker_db.name
  description = "eventstracker database name"
}

output "runsapp_db_name" {
  value       = digitalocean_database_db.runsapp_db.name
  description = "runs-app database name"
}

output "runsai_db_name" {
  value       = digitalocean_database_db.runsai_db.name
  description = "runs-ai-analyzer database name"
}

# Spaces bucket removed - use prod-stop.sh to export data manually
# or configure Spaces separately with additional credentials

output "connection_string_eventstracker" {
  value       = "postgresql://${digitalocean_database_user.app_user.name}@${digitalocean_database_cluster.postgres.host}:${digitalocean_database_cluster.postgres.port}/${digitalocean_database_db.eventstracker_db.name}"
  description = "PostgreSQL connection string for eventstracker"
  sensitive   = true
}

output "connection_string_runsapp" {
  value       = "postgresql://${digitalocean_database_user.app_user.name}@${digitalocean_database_cluster.postgres.host}:${digitalocean_database_cluster.postgres.port}/${digitalocean_database_db.runsapp_db.name}"
  description = "PostgreSQL connection string for runs-app"
  sensitive   = true
}

output "connection_string_runsai" {
  value       = "postgresql://${digitalocean_database_user.app_user.name}@${digitalocean_database_cluster.postgres.host}:${digitalocean_database_cluster.postgres.port}/${digitalocean_database_db.runsai_db.name}"
  description = "PostgreSQL connection string for runs-ai-analyzer"
  sensitive   = true
}
