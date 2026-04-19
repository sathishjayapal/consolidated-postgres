#!/bin/bash

# RabbitMQ Stop Script
# This script cleanly stops and removes RabbitMQ containers

set -e  # Exit on error

COMPOSE_FILE="/Users/sathishjayapal/IdeaProjects/consolidated-postgres/rabbitmq-compose.yml"
PROJECT_NAME="consolidated-postgres"
CONTAINER_NAME="sathishproject-rabbitmq"

echo "=== RabbitMQ Stop Utility ==="
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

echo "Checking container status..."

if ! container_exists; then
    echo "ℹ️  Container '$CONTAINER_NAME' does not exist"
    echo "Nothing to stop"
    exit 0
fi

if container_running; then
    echo "🛑 Stopping RabbitMQ container..."
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    echo "✅ RabbitMQ stopped successfully"
else
    echo "ℹ️  Container exists but is not running"
    echo "Removing container..."
    docker rm "$CONTAINER_NAME"
    echo "✅ Container removed"
fi

echo ""
echo "🎉 RabbitMQ cleanup complete!"
