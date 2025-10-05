#!/bin/bash
set -e

# Cron daemon for PostgreSQL backups
# Runs backup script based on BACKUP_SCHEDULE environment variable

echo "$(date '+%Y-%m-%d %H:%M:%S') - PostgreSQL Backup Service Starting..."
echo "$(date '+%Y-%m-%d %H:%M:%S') - ============================================"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Schedule: ${BACKUP_SCHEDULE}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Host: ${PGHOST}:${PGPORT}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - User: ${PGUSER}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Local Retention: ${LOCAL_RETENTION_DAYS:-1} days"
echo "$(date '+%Y-%m-%d %H:%M:%S') - S3 Enabled: ${S3_ENABLED:-false}"
[ "$S3_ENABLED" = "true" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - S3 Retention: ${S3_RETENTION_DAYS:-7} days"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Rsync Enabled: ${RSYNC_ENABLED:-false}"
[ "$RSYNC_ENABLED" = "true" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - Rsync Retention: ${RSYNC_RETENTION_DAYS:-30} days"
echo "$(date '+%Y-%m-%d %H:%M:%S') - ============================================"

# Backup script is already copied to /tmp/ and made executable by the container command

# Create cron job
echo "${BACKUP_SCHEDULE} /tmp/backup-script.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

# Create log file
touch /var/log/backup.log

# Start cron daemon in background
crond -f -l 2 &

# Run initial backup
echo "$(date '+%Y-%m-%d %H:%M:%S') - Running initial backup..."
/tmp/backup-script.sh

# Calculate next run time
echo "$(date '+%Y-%m-%d %H:%M:%S') - ============================================"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Initial backup completed"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Cron schedule: ${BACKUP_SCHEDULE}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Waiting for next scheduled backup..."
echo "$(date '+%Y-%m-%d %H:%M:%S') - ============================================"

# Keep container running and tail logs
tail -f /var/log/backup.log