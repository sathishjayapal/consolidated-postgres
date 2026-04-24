# Event-Driven Integration Startup Guide

## Overview

The three-service integration (eventstracker, runs-app, runs-ai-analyzer) requires **specific startup order** to work correctly. This guide explains the automated startup process.

---

## Why Order Matters

```
eventstracker → provisions RabbitMQ queues
     ↓
runs-app → validates queues exist, publishes events
     ↓
runs-ai-analyzer → consumes events from queues
```

**If started out of order:**
- ❌ runs-app will fail: "Garmin API queue not found"
- ❌ runs-ai-analyzer won't receive events (no queue to listen to)

---

## Automated Startup (Recommended)

### 1. Start Infrastructure

```bash
cd /path/to/consolidated-postgres
./scripts/local/multi-dev-up.sh
```

This starts:
- ✅ PostgreSQL containers (all 3 databases)
- ✅ RabbitMQ container
- ✅ Config Server

### 2. Start All Services (Automated)

```bash
./scripts/local/start-all-services.sh
```

This script:
- ✅ **Idempotent** - safe to run multiple times
- ✅ **Ordered** - starts eventstracker → runs-app → runs-ai-analyzer
- ✅ **Health checks** - waits for each service to be ready
- ✅ **Verification** - confirms RabbitMQ consumers are connected
- ✅ **Background** - runs services in background with logs

**Logs:**
```bash
tail -f /tmp/eventstracker.log
tail -f /tmp/runs-app.log
tail -f /tmp/runs-ai-analyzer.log
```

### 3. Stop All Services

```bash
./scripts/local/stop-all-services.sh
```

---

## Manual Startup (Alternative)

If you prefer manual control:

### Terminal 1: EventTracker (MUST BE FIRST)

```bash
cd /Users/skminfotech/IdeaProjects/eventstracker
./mvnw spring-boot:run
```

**Wait for:**
```
✅ "Declared queue: q.sathishprojects.garmin.api.events"
✅ "Declared queue: q.sathishprojects.garmin.ops.events"
✅ "Started EventServiceApplication"
```

### Terminal 2: Runs App

```bash
cd /Users/skminfotech/IdeaProjects/runs-app
./mvnw spring-boot:run
```

**Wait for:**
```
✅ "Validated Garmin API queue exists"
✅ "Validated Garmin OPS queue exists"
✅ "Started RunsAppApplication"
```

### Terminal 3: Runs AI Analyzer

```bash
cd /Users/skminfotech/IdeaProjects/runs-ai-analyzer
./mvnw spring-boot:run
```

**Wait for:**
```
✅ "RabbitMQ listener factory configured"
✅ "Started RunsAiAnalyzerApplication"
```

---

## Verification

### Quick Check

```bash
cd /Users/skminfotech/IdeaProjects/runs-ai-analyzer
./diagnose_integration.sh
```

### Manual Verification

**1. Service Health:**
```bash
curl http://localhost:8082/actuator/health  # eventstracker
curl http://localhost:8080/actuator/health  # runs-app
curl http://localhost:8081/actuator/health  # runs-ai-analyzer
```

**2. RabbitMQ Queues:**
```bash
docker exec sathishproject-rabbitmq rabbitmqctl list_queues name consumers
```

**Expected:**
```
q.sathishprojects.garmin.api.events    1  # eventstracker
q.sathishprojects.garmin.ops.events    1  # runs-ai-analyzer
```

**3. Database Counts:**
```bash
# runs-app
psql -h localhost -p 5443 -U postgres -d runsapp_db -c \
  "SELECT COUNT(*) FROM garmin_run;"

# eventstracker
psql -h localhost -p 5442 -U postgres -d eventstracker -c \
  "SELECT COUNT(*) FROM domain_event WHERE event_type='GARMIN';"

# runs-ai-analyzer
psql -h localhost -p 5444 -U postgres -d runs-ai-analyzer -c \
  "SELECT COUNT(*) FROM analysis_processing_log;"
```

---

## Testing the Integration

### 1. Import a CSV File

```bash
cat > /tmp/test_run.csv << 'EOF'
Activity Type,Date,Distance,Calories,Time,Avg HR,Max HR,Activity Id,Activity Name
Running,2026-04-23 08:00:00,5.5,450,00:28:30,155,165,TEST999,Integration Test
EOF

cp /tmp/test_run.csv /data/garmin-fit-files/
```

### 2. Watch the Flow

**runs-app logs:**
```
✅ "Imported CSV activity: TEST999 (DB id: ...)"
✅ "Published SUCCESS event to API queue for CSV activity: TEST999"
✅ "Published SUCCESS event to OPS queue for CSV activity: TEST999"
```

**eventstracker logs:**
```
✅ "=== Received Garmin event from RabbitMQ ==="
✅ "Persisted Garmin event payload for EventId=..."
```

**runs-ai-analyzer logs:**
```
✅ "Received Garmin event message"
✅ "Queued Garmin run for analysis: activityId=TEST999"
✅ (After 30s) "Processing batch of 1 pending events"
```

### 3. Verify Databases

```bash
# eventstracker - should have the event
psql -h localhost -p 5442 -U postgres -d eventstracker -c \
  "SELECT COUNT(*) FROM domain_event WHERE payload LIKE '%TEST999%';"

# runs-ai-analyzer - should have processing log
psql -h localhost -p 5444 -U postgres -d runs-ai-analyzer -c \
  "SELECT activity_id, processing_status FROM analysis_processing_log WHERE activity_id='TEST999';"
```

---

## Idempotency Guarantees

### Service Level
- ✅ `start-all-services.sh` checks if services are already running
- ✅ Won't start duplicates
- ✅ Safe to run multiple times

### Application Level
- ✅ **runs-ai-analyzer** uses database unique constraint on `(activity_id, database_id)`
- ✅ Duplicate events won't create duplicate processing logs
- ✅ Idempotent even if same event published multiple times

### Test Idempotency

```bash
# Import same file twice
cp /tmp/test_run.csv /data/garmin-fit-files/test_run_2.csv

# Check processing logs - should still be 1
psql -h localhost -p 5444 -U postgres -d runs-ai-analyzer -c \
  "SELECT COUNT(*) FROM analysis_processing_log WHERE activity_id='TEST999';"
# Expected: 1 (not 2)
```

---

## Troubleshooting

### Issue: "Queue not found" error

**Cause:** eventstracker not started first

**Fix:**
```bash
./scripts/local/stop-all-services.sh
./scripts/local/start-all-services.sh
```

### Issue: No events in runs-ai-analyzer

**Check:**
1. RabbitMQ queues exist
2. runs-app publishing to OPS queue
3. runs-ai-analyzer has consumer connected

**Diagnose:**
```bash
cd /Users/skminfotech/IdeaProjects/runs-ai-analyzer
./diagnose_integration.sh
```

### Issue: Services won't stop

**Force kill:**
```bash
pkill -9 -f "spring-boot:run"
```

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                    consolidated-postgres                     │
│  (Infrastructure Management)                                 │
│                                                              │
│  ├─ multi-dev-up.sh          → Start DBs + RabbitMQ        │
│  ├─ start-all-services.sh    → Start apps in order         │
│  └─ stop-all-services.sh     → Stop all apps               │
└─────────────────────────────────────────────────────────────┘
                              ↓
        ┌─────────────────────┼─────────────────────┐
        ↓                     ↓                     ↓
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│ eventstracker│      │   runs-app   │      │runs-ai-      │
│              │      │              │      │analyzer      │
│ Port: 8082   │      │ Port: 8080   │      │ Port: 8081   │
│              │      │              │      │              │
│ Provisions   │      │ Publishes    │      │ Consumes     │
│ RabbitMQ     │      │ events to    │      │ events from  │
│ queues       │      │ 2 queues     │      │ OPS queue    │
│              │      │              │      │              │
│ Consumes     │      │              │      │ Batch        │
│ API queue    │      │              │      │ processing   │
│ (audit)      │      │              │      │ (AI analysis)│
└──────────────┘      └──────────────┘      └──────────────┘
```

---

## Quick Reference

### Start Everything
```bash
cd /path/to/consolidated-postgres
./scripts/local/multi-dev-up.sh
./scripts/local/start-all-services.sh
```

### Stop Everything
```bash
./scripts/local/stop-all-services.sh
./scripts/local/multi-dev-down.sh
```

### Diagnose Issues
```bash
cd /Users/skminfotech/IdeaProjects/runs-ai-analyzer
./diagnose_integration.sh
```

### View Logs
```bash
tail -f /tmp/eventstracker.log
tail -f /tmp/runs-app.log
tail -f /tmp/runs-ai-analyzer.log
```

---

## Success! 🎉

When everything is working:
- ✅ All 3 services running
- ✅ RabbitMQ queues provisioned
- ✅ 2 consumers connected (eventstracker + runs-ai-analyzer)
- ✅ Events flowing: runs-app → eventstracker (audit) + runs-ai-analyzer (analysis)
- ✅ Idempotent: No duplicate processing
- ✅ Resilient: DLQ + retry + reconciliation

**You're ready for production!** 🚀
