#!/bin/bash

# RabbitMQ Manager - Comprehensive utility for managing RabbitMQ containers
# Usage: ./rabbitmq-manager.sh [start|stop|restart|status|logs|clean]

set -e  # Exit on error

COMPOSE_FILE="/Users/sathishjayapal/IdeaProjects/consolidated-postgres/rabbitmq-compose.yml"
PROJECT_NAME="consolidated-postgres"
CONTAINER_NAME="sathishproject-rabbitmq"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Function to check if container exists
container_exists() {
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Function to check if container is running
container_running() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Function to remove orphaned containers
remove_orphans() {
    print_info "Checking for orphaned containers..."
    ORPHANS=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}' | grep -v "$CONTAINER_NAME" || true)
    
    if [ -n "$ORPHANS" ]; then
        print_warning "Found orphaned containers: $ORPHANS"
        echo "$ORPHANS" | xargs -r docker rm -f
        print_success "Orphaned containers removed"
    else
        print_success "No orphaned containers found"
    fi
}

# Function to start RabbitMQ
start_rabbitmq() {
    echo ""
    echo "=== Starting RabbitMQ ==="
    
    if container_exists; then
        print_warning "Container '$CONTAINER_NAME' already exists"
        
        if container_running; then
            print_info "Container is already running"
            show_status
            return 0
        else
            print_info "Removing stopped container..."
            docker rm "$CONTAINER_NAME"
        fi
    fi
    
    remove_orphans
    
    print_info "Starting RabbitMQ with docker-compose..."
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d --remove-orphans
    
    print_info "Waiting for container to be ready..."
    sleep 3
    
    if container_running; then
        print_success "RabbitMQ started successfully!"
        show_status
    else
        print_error "Failed to start RabbitMQ"
        show_logs
        exit 1
    fi
}

# Function to stop RabbitMQ
stop_rabbitmq() {
    echo ""
    echo "=== Stopping RabbitMQ ==="
    
    if ! container_exists; then
        print_info "Container does not exist. Nothing to stop."
        return 0
    fi
    
    if container_running; then
        print_info "Stopping RabbitMQ..."
        docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
        print_success "RabbitMQ stopped successfully"
    else
        print_info "Container exists but is not running. Removing..."
        docker rm "$CONTAINER_NAME"
        print_success "Container removed"
    fi
}

# Function to restart RabbitMQ
restart_rabbitmq() {
    echo ""
    echo "=== Restarting RabbitMQ ==="
    stop_rabbitmq
    sleep 2
    start_rabbitmq
}

# Function to show status
show_status() {
    echo ""
    echo "=== RabbitMQ Status ==="
    
    if container_running; then
        print_success "RabbitMQ is RUNNING"
        echo ""
        docker ps --filter "name=^/${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        print_info "Management UI: http://localhost:15672"
        print_info "AMQP Port: 5672"
        print_info "Default credentials: guest/guest"
    elif container_exists; then
        print_warning "RabbitMQ container exists but is NOT RUNNING"
        docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}"
    else
        print_info "RabbitMQ container does not exist"
    fi
}

# Function to show logs
show_logs() {
    echo ""
    echo "=== RabbitMQ Logs (last 50 lines) ==="
    
    if container_exists; then
        docker logs "$CONTAINER_NAME" --tail 50
    else
        print_error "Container does not exist. No logs available."
    fi
}

# Function to clean everything
clean_all() {
    echo ""
    echo "=== Cleaning All RabbitMQ Resources ==="
    
    print_warning "This will remove all containers, volumes, and networks for $PROJECT_NAME"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Stopping and removing all resources..."
        docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down -v --remove-orphans
        print_success "All resources cleaned successfully"
    else
        print_info "Clean operation cancelled"
    fi
}

# Function to show usage
show_usage() {
    echo "RabbitMQ Manager - Comprehensive utility for managing RabbitMQ containers"
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  start      Start RabbitMQ (handles conflicts automatically)"
    echo "  stop       Stop RabbitMQ cleanly"
    echo "  restart    Restart RabbitMQ"
    echo "  status     Show RabbitMQ status"
    echo "  logs       Show RabbitMQ logs (last 50 lines)"
    echo "  clean      Remove all RabbitMQ resources (containers, volumes, networks)"
    echo "  help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 start"
    echo "  $0 status"
    echo "  $0 logs"
}

# Main script logic
case "${1:-}" in
    start)
        start_rabbitmq
        ;;
    stop)
        stop_rabbitmq
        ;;
    restart)
        restart_rabbitmq
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    clean)
        clean_all
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        if [ -z "${1:-}" ]; then
            print_error "No command specified"
        else
            print_error "Unknown command: $1"
        fi
        echo ""
        show_usage
        exit 1
        ;;
esac
