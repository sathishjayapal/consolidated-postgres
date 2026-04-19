# RabbitMQ Management Utilities

This directory contains utility scripts to manage RabbitMQ containers without encountering conflicts.

## 🚀 Quick Start

### Recommended: Use the Manager Script

```bash
# Start RabbitMQ (handles all conflicts automatically)
./rabbitmq-manager.sh start

# Check status
./rabbitmq-manager.sh status

# View logs
./rabbitmq-manager.sh logs

# Restart
./rabbitmq-manager.sh restart

# Stop
./rabbitmq-manager.sh stop

# Clean everything (removes volumes too)
./rabbitmq-manager.sh clean
```

## 📋 Available Scripts

### 1. **rabbitmq-manager.sh** (Recommended)
Comprehensive management utility with multiple commands.

**Commands:**
- `start` - Start RabbitMQ with automatic conflict resolution
- `stop` - Stop RabbitMQ cleanly
- `restart` - Restart RabbitMQ
- `status` - Show current status and connection info
- `logs` - Display last 50 log lines
- `clean` - Remove all resources (containers, volumes, networks)
- `help` - Show usage information

**Features:**
- ✅ Automatically handles container name conflicts
- ✅ Removes orphaned containers
- ✅ Colored output for better readability
- ✅ Status verification after startup
- ✅ Error handling and logging

### 2. **start-rabbitmq.sh**
Standalone script to start RabbitMQ with conflict resolution.

```bash
./start-rabbitmq.sh
```

### 3. **stop-rabbitmq.sh**
Standalone script to stop RabbitMQ cleanly.

```bash
./stop-rabbitmq.sh
```

## 🔧 What These Scripts Fix

### The Problem
When running `docker compose up`, you might encounter:
```
Error: The container name "/sathishproject-rabbitmq" is already in use
```

### The Solution
These scripts automatically:
1. ✅ Check if container exists
2. ✅ Stop running containers
3. ✅ Remove existing containers
4. ✅ Clean up orphaned containers
5. ✅ Start fresh container
6. ✅ Verify successful startup

## 📊 RabbitMQ Access Information

After starting RabbitMQ:

- **Management UI**: http://localhost:15672
- **AMQP Port**: 5672
- **Default Username**: guest
- **Default Password**: guest

## 🛠️ Troubleshooting

### Container won't start
```bash
# Check logs
./rabbitmq-manager.sh logs

# Try cleaning everything and starting fresh
./rabbitmq-manager.sh clean
./rabbitmq-manager.sh start
```

### Port already in use
```bash
# Check what's using the ports
lsof -i :5672
lsof -i :15672

# Stop other RabbitMQ instances
./rabbitmq-manager.sh stop
```

### Orphaned containers
```bash
# The scripts automatically handle this, but you can also manually clean:
docker ps -a --filter "label=com.docker.compose.project=consolidated-postgres"
```

## 📝 Manual Docker Commands (Not Recommended)

If you prefer manual control:

```bash
# Stop and remove container
docker stop sathishproject-rabbitmq
docker rm sathishproject-rabbitmq

# Start with compose
docker compose -f rabbitmq-compose.yml -p consolidated-postgres up -d --remove-orphans

# View logs
docker logs sathishproject-rabbitmq

# Stop with compose
docker compose -f rabbitmq-compose.yml -p consolidated-postgres down
```

## 🎯 Best Practices

1. **Always use the manager script** for consistent behavior
2. **Check status** before starting: `./rabbitmq-manager.sh status`
3. **View logs** if something goes wrong: `./rabbitmq-manager.sh logs`
4. **Clean periodically** to remove unused volumes: `./rabbitmq-manager.sh clean`

## 🔄 Integration with IDE

You can configure your IDE to use these scripts:

### IntelliJ IDEA / VS Code
Add run configurations:
- **Start RabbitMQ**: `./rabbitmq-manager.sh start`
- **Stop RabbitMQ**: `./rabbitmq-manager.sh stop`
- **View Status**: `./rabbitmq-manager.sh status`

## 📚 Additional Resources

- [RabbitMQ Documentation](https://www.rabbitmq.com/documentation.html)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [RabbitMQ Management Plugin](https://www.rabbitmq.com/management.html)

## 🐛 Reporting Issues

If you encounter issues with these scripts, check:
1. Docker is running
2. You have permission to execute scripts
3. The compose file path is correct
4. Ports 5672 and 15672 are available

---

**Last Updated**: April 2026
**Maintainer**: Sathish Jayapal
