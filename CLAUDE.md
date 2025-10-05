# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a PostgreSQL disaster recovery system with two components:

1. **Backup Service** - Automated backups to multiple destinations (local, S3, remote via rsync)
2. **Restore Tool** - Interactive CLI for easy restore operations

## Architecture

### Backup Service

The backup system consists of two main bash scripts:

1. **backup-cron.sh** - Entry point that sets up the cron daemon, schedules backup jobs based on `BACKUP_SCHEDULE` env var, and runs an initial backup on container start
2. **backup-script.sh** - Main backup logic that:
   - Creates full cluster backup using `pg_dumpall`
   - Creates globals-only backup (roles, tablespaces)
   - Creates individual database backups using `pg_dump`
   - Uploads to S3/DigitalOcean Spaces (if `S3_ENABLED=true`)
   - Syncs to remote server via rsync (if `RSYNC_ENABLED=true`)
   - Cleans up old backups based on retention settings

### Backup Folder Structure
Each backup run creates a timestamped folder containing all backup files:
```
backups/
└── 20251005_120000/              # Timestamp folder (YYYYMMDD_HHMMSS)
    ├── postgres_cluster.sql.gz   # Full cluster (pg_dumpall)
    ├── postgres_globals.sql.gz   # Roles/tablespaces only
    └── postgres_db_mydb.sql.gz   # Individual databases
```

### Restore Tool

Interactive CLI tool for discovering and restoring backups from any source (local/S3/remote).

**Helper libraries** (`lib/`):
- `backup-discovery.sh` - Discover backups from all sources
- `backup-download.sh` - Download backups from S3/rsync
- `restore-executor.sh` - Execute restore operations with verification

**Main script**:
- `restore-tool.sh` - Interactive menu-driven restore interface

### Expected File Locations

**On Docker host:**
- `/opt/gitops/dev/pg/backup-script.sh` - mounted read-only into container
- `/opt/gitops/dev/pg/backup-cron.sh` - mounted read-only into container
- `/opt/gitops/dev/pg/.env` - configuration file (not in git)
- `/opt/gitops/dev/pg/.ssh/` - SSH keys for rsync (optional)

**In container:**
- `/backups/` - backup files (Docker volume `postgres_backup_data`)
- `/var/log/backup.log` - backup operation logs
- `/tmp/backup-script.sh` - executable copy of backup script
- `/tmp/backup-cron.sh` - executable copy of cron wrapper

## Commands

### Deploy/Update Stack
```bash
docker stack deploy -c docker-compose.yml postgres-stack
```

### View Logs
```bash
docker service logs -f postgres-stack_postgres-backup
```

### Run Manual Backup
```bash
docker exec $(docker ps -q -f name=postgres-backup) /tmp/backup-script.sh
```

### List Backups
```bash
# List backup folders
ls -lh backups/

# Or from container
docker exec $(docker ps -q -f name=postgres-backup) ls -lh /backups
```

### Restore Using Interactive Tool (Recommended)

**Interactive mode:**
```bash
docker run --rm -it \
  -v $(pwd)/backups:/backups \
  --network your_postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=yourpassword \
  ghcr.io/user/pg-backups-restore:17-alpine
```

**Non-interactive mode (automation):**
```bash
docker run --rm \
  -v $(pwd)/backups:/backups \
  --network your_postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=yourpassword \
  -e RESTORE_SOURCE=local \
  -e RESTORE_FOLDER=20251005_120000 \
  -e RESTORE_TYPE=cluster \
  ghcr.io/user/pg-backups-restore:17-alpine
```

**With S3 access:**
```bash
docker run --rm -it \
  -v $(pwd)/restore:/restore \
  --network your_postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=yourpassword \
  -e S3_ENABLED=true \
  -e S3_BUCKET=your-bucket \
  -e S3_REGION=fra1 \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://fra1.digitaloceanspaces.com \
  ghcr.io/user/pg-backups-restore:17-alpine
```

### Manual Restore (Alternative)
```bash
# Restore full cluster
BACKUP_FOLDER="20251005_120000"
gunzip -c backups/${BACKUP_FOLDER}/postgres_cluster.sql.gz | \
    docker exec -i postgres-primary psql -U postgres

# Restore single database
DB_NAME="mydb"
gunzip -c backups/${BACKUP_FOLDER}/postgres_db_${DB_NAME}.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

## Configuration

All configuration is done via environment variables in `.env` file (use `.env.example` as template).

### Key Environment Variables

**PostgreSQL Connection:**
- `PGHOST` - PostgreSQL hostname (default: `postgres-primary`)
- `PGPORT` - PostgreSQL port (default: `5432`)
- `PGUSER`, `PGPASSWORD` - Database credentials

**Backup Settings:**
- `BACKUP_SCHEDULE` - Cron expression (e.g., `0 */6 * * *` for every 6 hours)
- `LOCAL_RETENTION_DAYS` - Days to keep backups on local volume (default: `1`)

**S3/Spaces:**
- `S3_ENABLED` - Set to `true` to enable S3 uploads
- `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_ENDPOINT`
- `S3_RETENTION_DAYS` - Days to keep backups in S3 (default: `7`)

**Rsync:**
- `RSYNC_ENABLED` - Set to `true` to enable remote sync
- `RSYNC_HOST`, `RSYNC_USER`, `RSYNC_PORT`, `RSYNC_PATH`
- `RSYNC_RETENTION_DAYS` - Days to keep backups on remote server (default: `30`)

### Recommended Settings

**Development:**
```bash
BACKUP_SCHEDULE=0 */6 * * *
LOCAL_RETENTION_DAYS=1
S3_RETENTION_DAYS=7
RSYNC_ENABLED=false
```

**Production:**
```bash
BACKUP_SCHEDULE=0 */2 * * *
LOCAL_RETENTION_DAYS=2
S3_RETENTION_DAYS=30
RSYNC_ENABLED=true
RSYNC_RETENTION_DAYS=90
```

## Docker Images

The project builds two Docker images:

1. **Backup Image** (`Dockerfile.backup-17-alpine`)
   - Automated scheduled backups
   - Runs as a service with cron
   - Tag: `ghcr.io/user/pg-backups:17-alpine`

2. **Restore Image** (`Dockerfile.restore-17-alpine`)
   - Interactive restore tool
   - Run on-demand for recovery operations
   - Tag: `ghcr.io/user/pg-backups-restore:17-alpine`

Both built automatically via GitHub Actions on push to main/master.

## Important Implementation Details

**Backup Service:**
- Container uses `postgres:17-alpine` image and installs `aws-cli`, `openssh-client`, `rsync` on startup
- Scripts are copied from read-only mounts to `/tmp/` and made executable on container start
- Cron daemon runs in background while main process tails log file to keep container running
- Initial backup runs immediately on container start before cron schedule begins
- S3 configuration supports DigitalOcean Spaces with custom endpoint URLs
- Rsync requires SSH key to be mounted at `/root/.ssh/id_rsa` (commented out by default in docker-compose.yml)
- Logging is configured to send to Loki at `loki.devops.skyconnect.co.tz` with service labels
- Backups are organized in timestamped folders (e.g., `20251005_120000/`)
- Each backup folder contains cluster, globals, and individual database backups
- Folder-based uploads to S3/rsync for better organization and atomic operations

**Restore Tool:**
- Interactive CLI with color-coded output and clear menus
- Automatically discovers backups from local/S3/remote sources
- Downloads backups from S3/remote only when needed
- Verifies backup integrity before restore
- Supports both interactive and non-interactive modes (for automation)
- Helper libraries in `lib/` for modular functionality
- Non-interactive mode controlled via environment variables:
  - `RESTORE_SOURCE` - local/s3/remote
  - `RESTORE_FOLDER` - timestamp folder name
  - `RESTORE_TYPE` - cluster/globals/database
  - `RESTORE_DATABASE` - database name (if RESTORE_TYPE=database)

## Testing

The README.md contains comprehensive testing procedures including:
- Monthly restore test workflow
- Backup integrity verification (gzip test)
- Storage usage monitoring
- Health check script example

Refer to README.md sections "Testing" and "Monitoring" for detailed procedures.
