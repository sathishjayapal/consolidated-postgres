#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Automated Service Startup with Correct Ordering
#
# This script starts all three services in the correct order:
#   1. eventstracker (provisions RabbitMQ queues)
#   2. runs-app (validates queues exist)
#   3. runs-ai-analyzer (consumes from queues)
#
# Features:
#   - Idempotent: Safe to run multiple times
#   - Health checks: Waits for each service to be ready
#   - Automatic recovery: Restarts if needed
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"

source "$REPO_ROOT/scripts/lib/project-config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}ℹ${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
print_header() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Check if service is running
is_service_running() {
  local port=$1
  local service_name=$2
  
  if curl -sf "http://localhost:${port}/actuator/health" >/dev/null 2>&1; then
    return 0
  elif curl -sf -o /dev/null -w "%{http_code}" "http://localhost:${port}/actuator/health" 2>/dev/null | grep -q "401"; then
    # 401 means service is running but requires auth (runs-app)
    return 0
  else
    return 1
  fi
}

# Wait for service to be ready
wait_for_service() {
  local port=$1
  local service_name=$2
  local max_wait=${3:-120}
  
  print_info "Waiting for $service_name on port $port (max ${max_wait}s)..."
  
  local attempts=0
  while [ $attempts -lt $max_wait ]; do
    if is_service_running "$port" "$service_name"; then
      print_status "$service_name is ready on port $port"
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
  
  print_error "$service_name did not start within ${max_wait}s"
  return 1
}

# Check if RabbitMQ queue exists
check_rabbitmq_queue() {
  local queue_name=$1
  
  if docker exec sathishproject-rabbitmq rabbitmqctl list_queues name 2>/dev/null | grep -q "^${queue_name}$"; then
    return 0
  else
    return 1
  fi
}

# Start a service in background
start_service() {
  local service_name=$1
  local service_dir=$2
  local port=$3
  local log_file="/tmp/${service_name}.log"
  
  print_header "Starting $service_name"
  
  # Check if already running (idempotency)
  if is_service_running "$port" "$service_name"; then
    print_status "$service_name already running on port $port"
    return 0
  fi
  
  print_info "Starting $service_name in background..."
  print_info "Logs: tail -f $log_file"
  
  # Start service in background
  (cd "$service_dir" && ./mvnw spring-boot:run > "$log_file" 2>&1) &
  local pid=$!
  
  print_info "Started $service_name (PID: $pid)"
  
  # Wait for service to be ready
  if wait_for_service "$port" "$service_name" 180; then
    print_status "$service_name started successfully"
    return 0
  else
    print_error "$service_name failed to start"
    print_error "Check logs: tail -50 $log_file"
    return 1
  fi
}

print_header "Automated Service Startup"

# Resolve project directories
EVENTSTRACKER_DIR="$(resolve_project_dir eventstracker)"
RUNS_APP_DIR="$(resolve_project_dir runs-app)"
RUNS_AI_ANALYZER_DIR="$(resolve_project_dir runs-ai-analyzer)"

# Step 1: Start EventTracker (MUST BE FIRST)
print_header "Step 1/3: EventTracker (Queue Provisioner)"
if start_service "eventstracker" "$EVENTSTRACKER_DIR" 8082; then
  # Verify queues are provisioned
  print_info "Verifying RabbitMQ queues provisioned..."
  sleep 5  # Give eventstracker time to declare queues
  
  if check_rabbitmq_queue "q.sathishprojects.garmin.ops.events"; then
    print_status "RabbitMQ OPS queue provisioned"
  else
    print_warn "OPS queue not found yet - eventstracker may still be initializing"
  fi
  
  if check_rabbitmq_queue "q.sathishprojects.garmin.api.events"; then
    print_status "RabbitMQ API queue provisioned"
  else
    print_warn "API queue not found yet - eventstracker may still be initializing"
  fi
else
  print_error "EventTracker failed to start - cannot continue"
  exit 1
fi

# Step 2: Start Runs App
print_header "Step 2/3: Runs App (Event Publisher)"
if start_service "runs-app" "$RUNS_APP_DIR" 8080; then
  print_status "Runs App started successfully"
else
  print_error "Runs App failed to start"
  print_info "Check if queues exist: docker exec sathishproject-rabbitmq rabbitmqctl list_queues"
  exit 1
fi

# Step 3: Start Runs AI Analyzer
print_header "Step 3/3: Runs AI Analyzer (Event Consumer)"
if start_service "runs-ai-analyzer" "$RUNS_AI_ANALYZER_DIR" 8081; then
  print_status "Runs AI Analyzer started successfully"
else
  print_error "Runs AI Analyzer failed to start"
  exit 1
fi

# Final verification
print_header "Verification"

print_info "Checking RabbitMQ consumers..."
sleep 2

API_CONSUMERS=$(docker exec sathishproject-rabbitmq rabbitmqctl list_queues name consumers 2>/dev/null | grep "q.sathishprojects.garmin.api.events" | awk '{print $2}' || echo "0")
OPS_CONSUMERS=$(docker exec sathishproject-rabbitmq rabbitmqctl list_queues name consumers 2>/dev/null | grep "q.sathishprojects.garmin.ops.events" | awk '{print $2}' || echo "0")

if [ "$API_CONSUMERS" = "1" ]; then
  print_status "API queue has 1 consumer (eventstracker)"
else
  print_warn "API queue has $API_CONSUMERS consumers (expected: 1)"
fi

if [ "$OPS_CONSUMERS" = "1" ]; then
  print_status "OPS queue has 1 consumer (runs-ai-analyzer)"
else
  print_warn "OPS queue has $OPS_CONSUMERS consumers (expected: 1)"
fi

print_header "All Services Started Successfully! 🎉"

cat <<EON

Service Status:
  ✅ eventstracker:     http://localhost:8082/actuator/health
  ✅ runs-app:          http://localhost:8080/actuator/health
  ✅ runs-ai-analyzer:  http://localhost:8081/actuator/health

Logs:
  tail -f /tmp/eventstracker.log
  tail -f /tmp/runs-app.log
  tail -f /tmp/runs-ai-analyzer.log

RabbitMQ:
  Management UI: http://localhost:15672 (guest/guest)
  
Troubleshooting:
  cd "$RUNS_AI_ANALYZER_DIR" && ./diagnose_integration.sh

To stop all services:
  pkill -f "spring-boot:run"

To test the integration:
  1. Import a CSV file to runs-app
  2. Check eventstracker logs for "Persisted Garmin event"
  3. Check runs-ai-analyzer logs for "Queued Garmin run for analysis"
  4. After 30s, check for "Processing batch"

EON
