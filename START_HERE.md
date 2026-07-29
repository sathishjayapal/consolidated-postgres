# 🚀 START HERE - Prerequisites & Setup Guide

## New Machine Setup (Local Dev)

This repo is now on GitHub. On any new machine, clone it as a sibling of `eventstracker` and `jubilant-memory`:

```bash
cd ~/IdeaProjects   # or wherever you keep your projects
git clone https://github.com/sathishjayapal/consolidated-postgres.git
git clone https://github.com/sathishjayapal/eventstracker.git        # if not already cloned
git clone https://github.com/sathishjayapal/jubilant-memory.git       # if not already cloned
```

Then start local dev:
```bash
cd consolidated-postgres
./scripts/local/multi-dev-up.sh
```

Or start just eventstracker:
```bash
cd eventstracker
./eventtracker.sh dev
```

> **Note:** `terraform.tfvars` (DigitalOcean API token) is **gitignored** — you must create it manually on each machine if you need cloud infrastructure. See the Cloud Infrastructure section below.

---

## Cloud Infrastructure Status

**⚠️ IMPORTANT LIMITATION:**
- ✅ `scripts/prod/prod-start.sh` works on ANY computer (creates infrastructure)
- ✅ `scripts/prod/diagnose.sh` works on ANY computer (validates setup)
- ❌ `scripts/prod/prod-stop.sh` works ONLY on Tahoe (macOS 12.7.6 has socket errors)

**To shutdown infrastructure: Use Tahoe Mac**

---

## ⚙️ Prerequisites (Required on Every Machine)

### What You Need Installed

Before running ANY scripts in this folder, your machine must have:

#### 1. **Terraform** (Infrastructure as Code)
Used to CREATE and DESTROY cloud resources.

**Check if installed:**
```bash
terraform version
```

**Installation:**

macOS:
```bash
brew install terraform
```

Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install terraform
```

Windows:
- Download from: https://releases.hashicorp.com/terraform/
- Add to PATH or use full path

#### 2. **PostgreSQL Client Tools** (Database Management)
Used to backup and restore databases.

**Check if installed:**
```bash
psql --version
pg_dump --version
```

**Installation:**

macOS:
```bash
brew install postgresql
```

Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install postgresql-client
```

Windows:
- Download from: https://www.postgresql.org/download/windows/
- Or use WSL and follow Ubuntu instructions

#### 3. **jq** (JSON Query Tool)
Used by diagnostic scripts.

**Check if installed:**
```bash
jq --version
```

**Installation:**

macOS:
```bash
brew install jq
```

Ubuntu/Debian:
```bash
sudo apt-get install jq
```

Windows:
- Download from: https://stedolan.github.io/jq/download/
- Or use WSL and follow Ubuntu instructions

#### 4. **curl** (HTTP Client)
Used for API calls (usually pre-installed).

**Check if installed:**
```bash
curl --version
```

### ✅ Verification Checklist

Run this on your machine to verify all prerequisites:

```bash
echo "Checking prerequisites..."
terraform version && echo "✓ terraform" || echo "✗ terraform NOT FOUND"
psql --version && echo "✓ psql" || echo "✗ psql NOT FOUND"
pg_dump --version && echo "✓ pg_dump" || echo "✗ pg_dump NOT FOUND"
jq --version && echo "✓ jq" || echo "✗ jq NOT FOUND"
curl --version && echo "✓ curl" || echo "✗ curl NOT FOUND"
```

All should show "✓" before proceeding.

---

## 🔑 Required Files (Must Exist in This Folder)

These files are ESSENTIAL for the scripts to work:

| File | Purpose | Must Exist |
|------|---------|-----------|
| `scripts/prod/terraform.tf` | Infrastructure definition | ✅ Yes |
| `terraform.tfvars` | DigitalOcean API token & config | ✅ Yes |
| `scripts/prod/variables.tf` | Terraform variables | ✅ Yes |
| `env/.env.prod` | Generated after `scripts/prod/prod-start.sh` | ⚠️ After creation |
| `terraform.tfstate` | Infrastructure tracking | ⚠️ After creation |

**Check required files:**
```bash
ls -l scripts/prod/terraform.tf terraform.tfvars scripts/prod/variables.tf
```

All three must exist and have content.

---

## 🚀 Operations on Your Machine

### Operation 1: Create Infrastructure (First Time Only)

**Prerequisites:**
- ✅ Terraform installed
- ✅ DigitalOcean API token in `scripts/prod/terraform.tfvars`
- ✅ All three terraform files exist

**Run:**
```bash
./scripts/prod/prod-start.sh
```

**When prompted:**
```
Continue with creation? (yes/no)
```
Type: `yes`

**Result:**
- ✅ PostgreSQL cluster created on DigitalOcean
- ✅ 3 databases created (eventstracker_db, runsapp_db, runsai_db)
- ✅ `env/.env.prod` file generated with connection details
- ✅ `terraform.tfstate` created (tracks infrastructure)
- ⏱️ Takes 3-5 minutes
- 💰 Starts costing $0.67/day

### Operation 2: Stop Infrastructure (When Done)

**Prerequisites:**
- ✅ Terraform installed
- ✅ PostgreSQL client tools installed (psql, pg_dump)
- ✅ `terraform.tfstate` exists (infrastructure was created)
- ✅ `env/.env.prod` exists (connection details)

**Run:**
```bash
./scripts/prod/prod-stop.sh
```

**When prompted:**
```
Are you sure? Type 'yes' to continue:
```
Type: `yes`

**Result:**
- ✅ All database data exported to `./backups/backup-TIMESTAMP.sql`
- ✅ Infrastructure destroyed on DigitalOcean
- ✅ **All charges stopped immediately** 💰
- ✓ Backup saved for recovery
- ⏱️ Takes 1-2 minutes

### Operation 3: Validate Setup (Anytime)

**Prerequisites:**
- ✅ Terraform installed

**Run:**
```bash
./scripts/prod/diagnose.sh
```

**Result:**
- ✅ Checks all prerequisites
- ✅ Validates configuration files
- ✅ Tests DigitalOcean API access
- ✅ Shows infrastructure status

---

## 📋 Step-by-Step: Running on a NEW Computer

### For a Brand New Machine (Never Run Before)

1. **Install Prerequisites** (15 minutes)
   ```bash
   # macOS
   brew install terraform postgresql jq

   # Ubuntu/Debian
   sudo apt-get update
   sudo apt-get install terraform postgresql-client jq

   # Verify
   terraform version
   psql --version
   pg_dump --version
   jq --version
   ```

2. **Clone this repo** to your machine
   ```bash
   git clone https://github.com/sathishjayapal/consolidated-postgres.git
   cd consolidated-postgres
   ```
   - Create `terraform.tfvars` with your DigitalOcean API token (not in git — see Important Notes)
   - `env/.env.prod` is only needed if infrastructure already exists
   - `terraform.tfstate` is only needed if infrastructure already exists

3. **Navigate to Folder**
   ```bash
   cd consolidated-postgres
   ```

4. **Run Diagnostic** (verify setup)
   ```bash
   ./scripts/prod/diagnose.sh
   ```

5. **Create Infrastructure** (if needed)
   ```bash
   ./scripts/prod/prod-start.sh
   # Type: yes
   # Wait 3-5 minutes
   ```

6. **Stop Infrastructure** (when done coding)
   ```bash
   ./scripts/prod/prod-stop.sh
   # Type: yes
   # Wait 1-2 minutes
   ```

### For a Machine With Existing Infrastructure

If `terraform.tfstate` and `env/.env.prod` already exist:

1. **Install Prerequisites** (same as above)

2. **Copy This Folder** with ALL files

3. **Run Diagnostic** to verify
   ```bash
   ./scripts/prod/diagnose.sh
   ```

4. **Stop Infrastructure**
   ```bash
   ./scripts/prod/prod-stop.sh
   # Type: yes
   ```

---

## ⚠️ Important Notes

### terraform.tfvars Contains API Token
- File contains your DigitalOcean API token
- **DO NOT commit to git** or share publicly
- Add to `.gitignore`
- Keep secure if sharing folder

### env/.env.prod Contains Passwords
- File contains database passwords
- **DO NOT commit to git**
- Add to `.gitignore`
- Keep secure if sharing folder

### terraform.tfstate Tracks Infrastructure
- Contains infrastructure state
- **DO NOT modify manually**
- **DO NOT commit to git**
- Add to `.gitignore`
- Needed to destroy infrastructure later

### Backups Folder
- Created after `scripts/prod/prod-stop.sh` runs
- Contains SQL backup files
- Safe to keep, safe to backup
- Use for recovery if needed

---

## 🔄 Quick Reference by Use Case

### "I'm coding on my laptop and need cloud DB"
```bash
./scripts/prod/prod-start.sh      # Create infrastructure
# ... code and test ...
./scripts/prod/prod-stop.sh       # Stop infrastructure and charges
```

### "I need to work on another computer"
1. Install prerequisites on new computer
2. `git clone https://github.com/sathishjayapal/consolidated-postgres.git`
3. Create `scripts/prod/terraform.tfvars` with your DO token
4. Run `./scripts/prod/diagnose.sh` to verify
5. Run `./scripts/prod/prod-start.sh` if needed (or `./scripts/prod/prod-stop.sh` if already running)

### "I forgot if infrastructure is running"
```bash
./scripts/prod/diagnose.sh
# Shows current status
```

### "I need to backup before stopping"
```bash
./scripts/prod/prod-stop.sh
# Automatically backs up before destroying
# Backup saved in ./backups/ folder
```

### "I need to restore from backup"
```bash
./scripts/prod/prod-start.sh              # Recreate infrastructure
source env/.env.prod
psql -h $DB_HOST -U $DB_USERNAME -d eventstracker_db < backups/backup-*.sql
```

---

## 📞 Troubleshooting

**"terraform: command not found"**
→ Install terraform (see Prerequisites section)

**"psql: command not found" or "pg_dump: command not found"**
→ Install PostgreSQL client tools (see Prerequisites section)

**"jq: command not found"**
→ Install jq (see Prerequisites section)

**"No terraform state found"**
→ Infrastructure doesn't exist yet, run `./scripts/prod/prod-start.sh`

**"pg_dump failed"**
→ PostgreSQL client tools not installed, or network issue

**"DigitalOcean API access FAILED"**
→ Check API token in `terraform.tfvars` is valid

**"Connection to the error socket" or socket-related errors**
→ This occurs when PostgreSQL tries to use Unix socket (`/tmp/.s.PGSQL.5432`) instead of TCP for remote database connections.

**Root cause:** On macOS and Linux, PostgreSQL client tools default to Unix socket connections. For remote databases (like DigitalOcean), you must explicitly use TCP protocol with `--protocol=tcp`.

**Solution:**
```bash
# Always add --protocol=tcp for remote database connections
source env/.env.prod

# For pg_dump (backup)
PGPASSWORD="$DB_PASSWORD" pg_dump \
  -h $DB_HOST \
  -p $DB_PORT \
  -U $DB_USERNAME \
  -d eventstracker_db \
  --protocol=tcp \
  > backup.sql

# For psql (connection testing)
psql -h $DB_HOST -U $DB_USERNAME -d eventstracker_db --protocol=tcp
```

**Note:** The `scripts/prod/prod-stop.sh` script now includes `--protocol=tcp` automatically (fixed as of this session).

**Manual diagnostic steps if still failing:**
```bash
# Test with explicit TCP protocol
source env/.env.prod
psql -h $DB_HOST -U $DB_USERNAME -d eventstracker_db --protocol=tcp

# Test DigitalOcean API access
curl -H "Authorization: Bearer YOUR_DO_TOKEN" https://api.digitalocean.com/v2/account

# Test network connectivity
ping $DB_HOST

# Check PostgreSQL tools
psql --version
pg_dump --version
```

---

## For Complete Documentation

See: **SETUP_AND_OPERATIONS.md**

That file has:
- Full architecture explanation
- All bug fixes detailed
- Cost breakdown
- Advanced troubleshooting
- Recovery procedures
- Best practices

---

## Current Files in This Folder

- `scripts/prod/prod-start.sh` - Creates infrastructure
- `scripts/prod/prod-stop.sh` - Destroys infrastructure + backups
- `scripts/prod/diagnose.sh` - Validates setup
- `SETUP_AND_OPERATIONS.md` - Complete documentation
- `START_HERE.md` - This file (quick start)
- `scripts/prod/terraform.tf` - Infrastructure definition
- `terraform.tfvars` - Your DigitalOcean token & config
- `scripts/prod/variables.tf` - Terraform variables
- `env/.env.prod` - Generated (connection details)
- `terraform.tfstate` - Generated (infrastructure state)
- `backups/` - Generated (data backups)

---

## ✅ You're Ready!

1. ✅ Install prerequisites
2. ✅ Run `./scripts/prod/prod-start.sh` or `./scripts/prod/prod-stop.sh`
3. ✅ Done

The setup works on ANY computer as long as prerequisites are installed.
