# Docker Host Connection
variable "docker_host" {
  description = "Docker host URL (unix:///var/run/docker.sock for local VM)"
  type        = string
  default     = "unix:///var/run/docker.sock"
}

# ─────────────────────────────────────────────────────────────────────────────
# Spring Cloud Config Server
# ─────────────────────────────────────────────────────────────────────────────

variable "git_uri" {
  description = "Git repository URI for Spring Cloud Config"
  type        = string
  sensitive   = true
}

variable "encrypt_key" {
  description = "Spring Cloud Config encryption key"
  type        = string
  sensitive   = true
}

variable "config_server_username" {
  description = "Config server basic auth username"
  type        = string
}

variable "config_server_password" {
  description = "Config server basic auth password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# RabbitMQ
# ─────────────────────────────────────────────────────────────────────────────

variable "rabbitmq_default_user" {
  description = "RabbitMQ admin username"
  type        = string
}

variable "rabbitmq_default_pass" {
  description = "RabbitMQ admin password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# EventTracker Database
# ─────────────────────────────────────────────────────────────────────────────

variable "events_tracker_db_name" {
  description = "EventTracker database name"
  type        = string
}

variable "events_tracker_db_user" {
  description = "EventTracker database user"
  type        = string
}

variable "events_tracker_db_password" {
  description = "EventTracker database password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Runs App Database
# ─────────────────────────────────────────────────────────────────────────────

variable "runs_app_db_name" {
  description = "Runs App database name"
  type        = string
}

variable "runs_app_db_user" {
  description = "Runs App database user"
  type        = string
}

variable "runs_app_db_password" {
  description = "Runs App database password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Runs AI Analyzer Database (pgvector)
# ─────────────────────────────────────────────────────────────────────────────

variable "runs_ai_analyzer_db_name" {
  description = "Runs AI Analyzer database name"
  type        = string
}

variable "runs_ai_analyzer_db_user" {
  description = "Runs AI Analyzer database user"
  type        = string
}

variable "runs_ai_analyzer_db_password" {
  description = "Runs AI Analyzer database password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# DBCleaner Database
# ─────────────────────────────────────────────────────────────────────────────

variable "dbcleaner_db_name" {
  description = "DBCleaner database name"
  type        = string
}

variable "dbcleaner_db_user" {
  description = "DBCleaner database user"
  type        = string
}

variable "dbcleaner_db_password" {
  description = "DBCleaner database password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Sathish Logger Database
# ─────────────────────────────────────────────────────────────────────────────

variable "sathishlogger_db_name" {
  description = "Sathish Logger database name"
  type        = string
}

variable "sathishlogger_db_user" {
  description = "Sathish Logger database user"
  type        = string
}

variable "sathishlogger_db_password" {
  description = "Sathish Logger database password"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Event Domain (EventTracker initial user)
# ─────────────────────────────────────────────────────────────────────────────

variable "event_domain_user" {
  description = "Initial event-domain user for EventTracker seeding"
  type        = string
}

variable "event_domain_user_password" {
  description = "Password for initial event-domain user"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Application Settings
# ─────────────────────────────────────────────────────────────────────────────

variable "production" {
  description = "Production flag for runs-app (true/false)"
  type        = bool
  default     = false
}
