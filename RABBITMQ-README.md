# RabbitMQ Management Utilities

The `scripts/local/` directory contains utility scripts to manage RabbitMQ containers without encountering conflicts.

## 🚀 Quick Start

### Recommended: Use the Manager Script

```bash
# Start RabbitMQ (handles all conflicts automatically)
./scripts/local/rabbitmq-manager.sh start

# Check status
./scripts/local/rabbitmq-manager.sh status

# View logs
./scripts/local/rabbitmq-manager.sh logs

# Restart
./scripts/local/rabbitmq-manager.sh restart

# Stop
./scripts/local/rabbitmq-manager.sh stop

# Clean everything (removes volumes too)
./scripts/local/rabbitmq-manager.sh clean
```

## 📋 Available Scripts

### 1. **scripts/local/rabbitmq-manager.sh** (Recommended)
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

> The old standalone `start-rabbitmq.sh` / `stop-rabbitmq.sh` scripts were removed in July 2026 — `scripts/local/rabbitmq-manager.sh start` and `scripts/local/rabbitmq-manager.sh stop` cover them.

## 🔧 What This Script Fixes

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
./scripts/local/rabbitmq-manager.sh logs

# Try cleaning everything and starting fresh
./scripts/local/rabbitmq-manager.sh clean
./scripts/local/rabbitmq-manager.sh start
```

### Port already in use
```bash
# Check what's using the ports
lsof -i :5672
lsof -i :15672

# Stop other RabbitMQ instances
./scripts/local/rabbitmq-manager.sh stop
```

### Orphaned containers
```bash
# The scripts automatically handle this, but you can also manually clean:
# (scoped to the rabbitmq SERVICE label, not just the project — the project label is
# now shared with eventstracker/runs-app/runs-ai-analyzer/mytracker's databases too)
docker ps -a --filter "label=com.docker.compose.project=sathish-project-infra" --filter "label=com.docker.compose.service=rabbitmq"
```

## 📝 Manual Docker Commands (Not Recommended)

If you prefer manual control. **Always scope to the `rabbitmq` service explicitly** —
`compose/docker-compose-local.yml` is shared with every other local project's database
now, so a bare `up`/`down` with no service name would affect all of them:

```bash
# Stop and remove container
docker stop sathishproject-rabbitmq
docker rm sathishproject-rabbitmq

# Start with compose
docker compose -f compose/docker-compose-local.yml --env-file env/.env.local -p sathish-project-infra up -d rabbitmq

# View logs
docker logs sathishproject-rabbitmq

# Stop with compose
docker compose -f compose/docker-compose-local.yml --env-file env/.env.local -p sathish-project-infra rm -f -s rabbitmq
```

## 🎯 Best Practices

1. **Always use the manager script** for consistent behavior
2. **Check status** before starting: `./scripts/local/rabbitmq-manager.sh status`
3. **View logs** if something goes wrong: `./scripts/local/rabbitmq-manager.sh logs`
4. **Clean periodically** to remove unused volumes: `./scripts/local/rabbitmq-manager.sh clean`

## 🔄 Integration with IDE

You can configure your IDE to use these scripts:

### IntelliJ IDEA / VS Code
Add run configurations:
- **Start RabbitMQ**: `./scripts/local/rabbitmq-manager.sh start`
- **Stop RabbitMQ**: `./scripts/local/rabbitmq-manager.sh stop`
- **View Status**: `./scripts/local/rabbitmq-manager.sh status`

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
