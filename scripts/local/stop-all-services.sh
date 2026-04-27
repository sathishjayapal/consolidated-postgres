#!/usr/bin/env bash

#################################################################
# Stop All Spring Boot Services
#
# Gracefully stops all running Spring Boot services
#################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_info() { echo -e "${YELLOW}ℹ${NC} $1"; }

print_info "Stopping all Spring Boot services..."

# Find all spring-boot:run processes
PIDS=$(pgrep -f "spring-boot:run" || true)

if [ -z "$PIDS" ]; then
  print_info "No Spring Boot services running"
  exit 0
fi

echo "Found processes: $PIDS"

# Kill each process
for PID in $PIDS; do
  CMDLINE=$(ps -p $PID -o command= 2>/dev/null || echo "unknown")
  print_info "Stopping PID $PID: $CMDLINE"
  kill $PID 2>/dev/null || true
done

# Wait for processes to stop
print_info "Waiting for services to stop..."
sleep 3

# Force kill if still running
REMAINING=$(pgrep -f "spring-boot:run" || true)
if [ -n "$REMAINING" ]; then
  print_info "Force killing remaining processes..."
  pkill -9 -f "spring-boot:run" || true
fi

print_status "All services stopped"

# Clean up log files
print_info "Cleaning up log files..."
rm -f /tmp/eventstracker.log /tmp/runs-app.log /tmp/runs-ai-analyzer.log

print_status "Done!"
