terraform {
  required_version = ">= 1.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }

  # State management (local for now, can move to S3/Consul later)
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "docker" {
  host = var.docker_host
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker Network (sathish-net bridge)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_network" "sathish_net" {
  name   = "sathish-net"
  driver = "bridge"
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker Volumes
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_volume" "pg_data_runs_ai_analyzer" {
  name = "pg_data_runs_ai_analyzer"
}

resource "docker_volume" "rabbitmq_data" {
  name = "rabbitmq_data"
}

resource "docker_volume" "logger_data" {
  name = "logger_data"
}

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL with pgvector (runs-ai-analyzer database)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "pgvector" {
  name          = "pgvector/pgvector:pg17"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "runs_ai_analyzer_db" {
  name    = "sathish-stack-runs-ai-analyzer-db-1"
  image   = docker_image.pgvector.image_id
  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=${var.runs_ai_analyzer_db_name}",
    "POSTGRES_USER=${var.runs_ai_analyzer_db_user}",
    "POSTGRES_PASSWORD=${var.runs_ai_analyzer_db_password}",
  ]

  ports {
    internal = 5432
    external = 5444
  }

  volumes {
    volume_name    = docker_volume.pg_data_runs_ai_analyzer.name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U ${var.runs_ai_analyzer_db_user} -d ${var.runs_ai_analyzer_db_name}"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 5
    start_period = "10s"
  }

  depends_on = [docker_network.sathish_net]
}

# ─────────────────────────────────────────────────────────────────────────────
# RabbitMQ Message Broker
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "rabbitmq" {
  name          = "rabbitmq:3-management-alpine"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "rabbitmq" {
  name    = "sathish-stack-rabbitmq-1"
  image   = docker_image.rabbitmq.image_id
  restart = "unless-stopped"

  env = [
    "RABBITMQ_DEFAULT_USER=${var.rabbitmq_default_user}",
    "RABBITMQ_DEFAULT_PASS=${var.rabbitmq_default_pass}",
  ]

  ports {
    internal = 5672
    external = 5672
  }

  ports {
    internal = 15672
    external = 15672
  }

  volumes {
    volume_name    = docker_volume.rabbitmq_data.name
    container_path = "/var/lib/rabbitmq"
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test         = ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
    interval     = "15s"
    timeout      = "10s"
    retries      = 5
    start_period = "10s"
  }

  depends_on = [docker_network.sathish_net]
}

# ─────────────────────────────────────────────────────────────────────────────
# Spring Cloud Config Server
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "config_server" {
  name          = "travelhelper0h/sathishproject-config-server:latest"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "config_server" {
  name    = "sathish-stack-config-server-1"
  image   = docker_image.config_server.image_id
  restart = "unless-stopped"

  env = [
    "GIT_URI=${var.git_uri}",
    "encrypt_key=${var.encrypt_key}",
    "SPRING_SECURITY_USER_NAME=${var.config_server_username}",
    "SPRING_SECURITY_USER_PASSWORD=${var.config_server_password}",
    "username=${var.config_server_username}",
    "pass=${var.config_server_password}",
  ]

  ports {
    internal = 8888
    external = 8888
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test = [
      "CMD-SHELL",
      "wget -qO- --header=\"Authorization: Basic $$(echo -n admin:admin | base64)\" http://localhost:8888/sathishconfigserver/info >/dev/null 2>&1 || exit 1"
    ]
    interval     = "20s"
    timeout      = "10s"
    retries      = 8
    start_period = "40s"
  }

  depends_on = [docker_network.sathish_net]
}

# ─────────────────────────────────────────────────────────────────────────────
# Sathish Logger (Centralized Logging)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "sathishlogger" {
  name          = "travelhelper0h/sathishlogger:latest"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "sathishlogger" {
  name    = "sathish-stack-sathishlogger-1"
  image   = docker_image.sathishlogger.image_id
  restart = "unless-stopped"

  env = [
    "SERVER_PORT=8080",
    "SPRING_PROFILES_ACTIVE=prod",
    "CONFIG_SERVER_URL=http://config-server:8888",
    "SPRING_CLOUD_CONFIG_USERNAME=${var.config_server_username}",
    "SPRING_CLOUD_CONFIG_PASSWORD=${var.config_server_password}",
    "DATABASE_URL=jdbc:postgresql://172.17.0.1:5432/${var.sathishlogger_db_name}",
    "DATABASE_USERNAME=${var.sathishlogger_db_user}",
    "DATABASE_PASSWORD=${var.sathishlogger_db_password}",
    "JPA_DDL_AUTO=update",
    "LOG_LEVEL=INFO",
    "STORAGE_TYPE=database",
    "LOG_RETENTION_DAYS=30",
  ]

  ports {
    internal = 8080
    external = 8090
  }

  volumes {
    volume_name    = docker_volume.logger_data.name
    container_path = "/app/data"
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  depends_on = [docker_container.config_server]
}

# ─────────────────────────────────────────────────────────────────────────────
# EventTracker Service
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "eventstracker" {
  name          = "travelhelper0h/eventstracker:latest"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "eventstracker" {
  name    = "sathish-stack-eventstracker-1"
  image   = docker_image.eventstracker.image_id
  restart = "unless-stopped"

  env = [
    "SPRING_PROFILES_ACTIVE=prod",
    "SERVER_PORT=9081",
    "CONFIG_SERVER_URL=http://config-server:8888",
    "SPRING_CLOUD_CONFIG_USERNAME=${var.config_server_username}",
    "SPRING_CLOUD_CONFIG_PASSWORD=${var.config_server_password}",
    "EVENTS_TRACKER_DB_URL=jdbc:postgresql://172.17.0.1:5432/${var.events_tracker_db_name}",
    "EVENTS_TRACKER_DB_USER=${var.events_tracker_db_user}",
    "EVENTS_TRACKER_DB_PASSWORD=${var.events_tracker_db_password}",
    "RABBITMQ_HOST=rabbitmq",
    "RABBITMQ_PORT=5672",
    "RABBITMQ_USERNAME=${var.rabbitmq_default_user}",
    "RABBITMQ_PASSWORD=${var.rabbitmq_default_pass}",
    "EVENT_DOMAIN_USER=${var.event_domain_user}",
    "EVENT_DOMAIN_USER_PASSWORD=${var.event_domain_user_password}",
    "SATHISHLOGGER_URL=http://sathishlogger:8080",
  ]

  ports {
    internal = 9081
    external = 9081
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://localhost:9081/actuator/health"]
    interval = "30s"
    timeout  = "10s"
    retries  = 3
  }

  depends_on = [docker_container.config_server, docker_container.rabbitmq]
}

# ─────────────────────────────────────────────────────────────────────────────
# DBCleaner Service
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "dbcleaner" {
  name          = "travelhelper0h/dbcleaner:latest"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "dbcleaner" {
  name    = "sathish-stack-dbcleaner-1"
  image   = docker_image.dbcleaner.image_id
  restart = "unless-stopped"

  env = [
    "SPRING_PROFILES_ACTIVE=docker",
    "SERVER_PORT=8085",
    "CONFIG_SERVER_URL=http://config-server:8888",
    "SPRING_CLOUD_CONFIG_USERNAME=${var.config_server_username}",
    "SPRING_CLOUD_CONFIG_PASSWORD=${var.config_server_password}",
    "JDBC_DATABASE_URL=jdbc:postgresql://172.17.0.1:5432/${var.dbcleaner_db_name}",
    "JDBC_DATABASE_USERNAME=${var.dbcleaner_db_user}",
    "JDBC_DATABASE_PASSWORD=${var.dbcleaner_db_password}",
    "RUNS_APP_DB_URL=jdbc:postgresql://172.17.0.1:5432/${var.runs_app_db_name}",
    "RUNS_APP_DB_USERNAME=${var.runs_app_db_user}",
    "RUNS_APP_DB_PASSWORD=${var.runs_app_db_password}",
    "EVENTS_TRACKER_DB_URL=jdbc:postgresql://172.17.0.1:5432/${var.events_tracker_db_name}",
    "EVENTS_TRACKER_DB_USERNAME=${var.events_tracker_db_user}",
    "EVENTS_TRACKER_DB_PASSWORD=${var.events_tracker_db_password}",
    "RUNS_AI_DB_URL=jdbc:postgresql://runs-ai-analyzer-db:5432/${var.runs_ai_analyzer_db_name}",
    "RUNS_AI_DB_USERNAME=${var.runs_ai_analyzer_db_user}",
    "RUNS_AI_DB_PASSWORD=${var.runs_ai_analyzer_db_password}",
  ]

  ports {
    internal = 8085
    external = 8085
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test         = ["CMD-SHELL", "wget -qO- http://localhost:8085/actuator/health >/dev/null 2>&1 || exit 1"]
    interval     = "20s"
    timeout      = "5s"
    retries      = 6
    start_period = "60s"
  }

  depends_on = [docker_container.config_server]
}

# ─────────────────────────────────────────────────────────────────────────────
# Runs App (Running Tracker)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "runs_app" {
  name          = "ghcr.io/sathishjayapal/runs-app:latest"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "runs_app" {
  name    = "sathish-stack-runs-app-1"
  image   = docker_image.runs_app.image_id
  restart = "unless-stopped"

  env = [
    "SPRING_PROFILES_ACTIVE=prod",
    "SERVER_PORT=8080",
    "CONFIG_SERVER_URL=http://config-server:8888",
    "SPRING_CLOUD_CONFIG_USERNAME=${var.config_server_username}",
    "SPRING_CLOUD_CONFIG_PASSWORD=${var.config_server_password}",
    "JDBC_DATABASE_URL=jdbc:postgresql://172.17.0.1:5432/${var.runs_app_db_name}",
    "JDBC_DATABASE_USERNAME=${var.runs_app_db_user}",
    "JDBC_DATABASE_PASSWORD=${var.runs_app_db_password}",
    "RABBITMQ_HOST=rabbitmq",
    "RABBITMQ_PORT=5672",
    "RABBITMQ_USERNAME=${var.rabbitmq_default_user}",
    "RABBITMQ_PASSWORD=${var.rabbitmq_default_pass}",
    "RUNS_AI_ANALYZER_URL=http://runs-ai-analyzer:8081",
    "PRODUCTION=${var.production}",
  ]

  ports {
    internal = 8080
    external = 8080
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test         = ["CMD", "wget", "-qO-", "http://localhost:8080/actuator/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "60s"
  }

  depends_on = [docker_container.config_server, docker_container.rabbitmq]
}

# ─────────────────────────────────────────────────────────────────────────────
# Runs AI Analyzer
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "runs_ai_analyzer" {
  name          = "ghcr.io/sathishjayapal/runs-ai-analyzer:latest"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "runs_ai_analyzer" {
  name    = "sathish-stack-runs-ai-analyzer-1"
  image   = docker_image.runs_ai_analyzer.image_id
  restart = "unless-stopped"

  env = [
    "SPRING_PROFILES_ACTIVE=prod",
    "SERVER_PORT=8081",
    "CONFIG_SERVER_URL=http://config-server:8888",
    "SPRING_CLOUD_CONFIG_USERNAME=${var.config_server_username}",
    "SPRING_CLOUD_CONFIG_PASSWORD=${var.config_server_password}",
    "RUNS_AI_ANALYZER_DB_URL=jdbc:postgresql://runs-ai-analyzer-db:5432/${var.runs_ai_analyzer_db_name}",
    "RUNS_AI_ANALYZER_DB_USER=${var.runs_ai_analyzer_db_user}",
    "RUNS_AI_ANALYZER_DB_PASSWORD=${var.runs_ai_analyzer_db_password}",
    "RABBITMQ_HOST=rabbitmq",
    "RABBITMQ_PORT=5672",
    "RABBITMQ_USERNAME=${var.rabbitmq_default_user}",
    "RABBITMQ_PASSWORD=${var.rabbitmq_default_pass}",
    "OLLAMA_BASE_URL=http://host.docker.internal:11434",
    "RUNS_APP_BASE_URL=http://runs-app:8080",
  ]

  ports {
    internal = 8081
    external = 8081
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  healthcheck {
    test         = ["CMD", "wget", "-qO-", "http://localhost:8081/actuator/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 3
    start_period = "60s"
  }

  depends_on = [docker_container.config_server, docker_container.runs_ai_analyzer_db, docker_container.rabbitmq]
}

# ─────────────────────────────────────────────────────────────────────────────
# Watchtower (Auto-update containers on new image)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "watchtower" {
  name          = "nickfedor/watchtower:1.20.3"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "watchtower" {
  name    = "sathish-stack-watchtower-1"
  image   = docker_image.watchtower.image_id
  restart = "unless-stopped"

  env = [
    "WATCHTOWER_POLL_INTERVAL=300",
    "WATCHTOWER_CLEANUP=true",
    "WATCHTOWER_INCLUDE_STOPPED=false",
    "WATCHTOWER_ROLLING_RESTART=false",
  ]

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  depends_on = [docker_network.sathish_net]
}

# ─────────────────────────────────────────────────────────────────────────────
# cAdvisor (Container Metrics)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "cadvisor" {
  name          = "ghcr.io/google/cadvisor:0.60.5"
  keep_locally  = false
  pull_image    = true
}

resource "docker_container" "cadvisor" {
  name      = "sathish-stack-cadvisor-1"
  image     = docker_image.cadvisor.image_id
  restart   = "unless-stopped"
  privileged = true

  ports {
    internal = 8080
    external = 9099
  }

  volumes {
    host_path      = "/"
    container_path = "/rootfs"
    read_only      = true
  }

  volumes {
    host_path      = "/var/run"
    container_path = "/var/run"
    read_only      = true
  }

  volumes {
    host_path      = "/sys"
    container_path = "/sys"
    read_only      = true
  }

  volumes {
    host_path      = "/var/lib/docker/"
    container_path = "/var/lib/docker/"
    read_only      = true
  }

  volumes {
    host_path      = "/dev/disk/"
    container_path = "/dev/disk/"
    read_only      = true
  }

  devices {
    host_path      = "/dev/kmsg"
    container_path = "/dev/kmsg"
  }

  networks_advanced {
    name = docker_network.sathish_net.name
  }

  depends_on = [docker_network.sathish_net]
}
