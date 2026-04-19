#!/bin/bash

# RabbitMQ Startup Script with Conflict Resolution
# This script ensures clean startup of RabbitMQ by handling container conflicts

set -e  # Exit on error

COMPOSE_FILE="/Users/sathishjayapal/IdeaProjects/consolidated-postgres/rabbitmq-compose.yml"
PROJECT_NAME="consolidated-postgres"
CONTAINER_NAME="sathishproject-rabbitmq"

echo "=== RabbitMQ Startup Utility ==="
echo "Project: $PROJECT_NAME"
echo "Container: $CONTAINER_NAME"
echo ""

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
    echo "🧹 Checking for orphaned containers..."
    ORPHANS=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}' | grep -v "$CONTAINER_NAME" || true)
    
    if [ -n "$ORPHANS" ]; then
        echo "Found orphaned containers:"
        echo "$ORPHANS"
        echo "Removing orphaned containers..."
        echo "$ORPHANS" | xargs -r docker rm -f
        echo "✅ Orphaned containers removed"
    else
        echo "✅ No orphaned containers found"
    fi
}

# Main logic
echo "Step 1: Checking container status..."

if container_exists; then
    echo "⚠️  Container '$CONTAINER_NAME' already exists"
    
    if container_running; then
        echo "ℹ️  Container is currently running"
        echo "Stopping container..."
        docker stop "$CONTAINER_NAME"
        echo "✅ Container stopped"
    else
        echo "ℹ️  Container exists but is not running"
    fi
    
    echo "Removing existing container..."
    docker rm "$CONTAINER_NAME"
    echo "✅ Container removed"
else
    echo "✅ No existing container found"
fi

echo ""
echo "Step 2: Cleaning up orphaned containers..."
remove_orphans

echo ""
echo "Step 3: Starting RabbitMQ with docker-compose..."
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d --remove-orphans

echo ""
echo "Step 4: Verifying container status..."
sleep 2

if container_running; then
    echo "✅ RabbitMQ container is running successfully!"
    echo ""
    echo "Container details:"
    docker ps --filter "name=^/${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "🎉 RabbitMQ is ready!"
    echo "   Management UI: http://localhost:15672"
    echo "   AMQP Port: 5672"
else
    echo "❌ Failed to start RabbitMQ container"
    echo "Checking logs..."
    docker logs "$CONTAINER_NAME" --tail 50
    exit 1
fi
