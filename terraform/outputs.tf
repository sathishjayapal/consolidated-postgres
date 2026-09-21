# ─────────────────────────────────────────────────────────────────────────────
# Service Endpoints
# ─────────────────────────────────────────────────────────────────────────────

output "config_server_url" {
  description = "Spring Cloud Config Server URL"
  value       = "http://localhost:8888"
}

output "eventstracker_url" {
  description = "EventTracker service URL"
  value       = "http://localhost:9081"
}

output "sathishlogger_url" {
  description = "Sathish Logger service URL"
  value       = "http://localhost:8090"
}

output "dbcleaner_url" {
  description = "DBCleaner service URL"
  value       = "http://localhost:8085"
}

output "runs_app_url" {
  description = "Runs App service URL (backend)"
  value       = "http://localhost:8080"
}

output "runs_app_frontend_url" {
  description = "Runs App frontend URL (dev server, if running)"
  value       = "http://localhost:3000"
}

output "runs_ai_analyzer_url" {
  description = "Runs AI Analyzer service URL"
  value       = "http://localhost:8081"
}

output "rabbitmq_url" {
  description = "RabbitMQ Management Console URL"
  value       = "http://localhost:15672"
}

output "cadvisor_url" {
  description = "cAdvisor Container Metrics URL"
  value       = "http://localhost:9099"
}

output "prometheus_url" {
  description = "Prometheus metrics server URL (remote VM)"
  value       = "http://192.168.4.101:9090"
}

output "grafana_url" {
  description = "Grafana dashboards URL (remote VM)"
  value       = "http://192.168.4.101:3000"
}

# ─────────────────────────────────────────────────────────────────────────────
# Database Connection Info
# ─────────────────────────────────────────────────────────────────────────────

output "runs_ai_analyzer_db" {
  description = "Runs AI Analyzer database connection details"
  value = {
    host     = "runs-ai-analyzer-db"
    port     = 5432
    database = var.runs_ai_analyzer_db_name
    user     = var.runs_ai_analyzer_db_user
    external_port = 5444
  }
  sensitive = true
}

output "native_postgresql" {
  description = "Native PostgreSQL on host (172.17.0.1:5432)"
  value = {
    host     = "172.17.0.1"
    port     = 5432
    message  = "Other databases are on native PostgreSQL via bridge IP"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Container Status
# ─────────────────────────────────────────────────────────────────────────────

output "container_ids" {
  description = "Docker container IDs deployed by Terraform"
  value = {
    config_server         = docker_container.config_server.id
    eventstracker         = docker_container.eventstracker.id
    sathishlogger         = docker_container.sathishlogger.id
    dbcleaner             = docker_container.dbcleaner.id
    runs_app              = docker_container.runs_app.id
    runs_ai_analyzer      = docker_container.runs_ai_analyzer.id
    runs_ai_analyzer_db   = docker_container.runs_ai_analyzer_db.id
    rabbitmq              = docker_container.rabbitmq.id
    watchtower            = docker_container.watchtower.id
    cadvisor              = docker_container.cadvisor.id
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Network Info
# ─────────────────────────────────────────────────────────────────────────────

output "docker_network" {
  description = "Docker bridge network for containers"
  value = {
    name   = docker_network.sathish_net.name
    driver = docker_network.sathish_net.driver
  }
}
