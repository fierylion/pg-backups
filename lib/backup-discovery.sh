#!/bin/bash
# backup-discovery.sh - Discover available backups from all sources

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Discover local backups
discover_local_backups() {
    local backup_dir="${1:-/backups}"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # Find timestamped backup folders
    find "$backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r
}

# Count local backups
count_local_backups() {
    local backup_dir="${1:-/backups}"
    discover_local_backups "$backup_dir" | wc -l
}

# Get backup folder size
get_backup_size() {
    local folder="$1"
    du -sh "$folder" 2>/dev/null | cut -f1
}

# Get backup age in hours
get_backup_age() {
    local folder="$1"
    local folder_name=$(basename "$folder")

    # Extract timestamp (YYYYMMDD_HHMMSS)
    local timestamp=$(echo "$folder_name" | grep -oE '[0-9]{8}_[0-9]{6}')

    if [ -z "$timestamp" ]; then
        echo "unknown"
        return
    fi

    # Parse timestamp
    local year=${timestamp:0:4}
    local month=${timestamp:4:2}
    local day=${timestamp:6:2}
    local hour=${timestamp:9:2}
    local minute=${timestamp:11:2}
    local second=${timestamp:13:2}

    # Get backup time in seconds since epoch
    local backup_time=$(date -d "${year}-${month}-${day} ${hour}:${minute}:${second}" +%s 2>/dev/null || \
                        date -r "$folder" +%s 2>/dev/null || \
                        echo "0")

    if [ "$backup_time" -eq 0 ]; then
        echo "unknown"
        return
    fi

    local current_time=$(date +%s)
    local age_seconds=$((current_time - backup_time))
    local age_hours=$((age_seconds / 3600))

    if [ $age_hours -lt 1 ]; then
        echo "< 1 hour"
    elif [ $age_hours -lt 24 ]; then
        echo "${age_hours} hours"
    else
        local age_days=$((age_hours / 24))
        echo "${age_days} days"
    fi
}

# Verify backup folder contains required files
verify_backup_folder() {
    local folder="$1"
    local has_cluster=false
    local has_globals=false
    local file_count=0

    if [ -f "$folder/postgres_cluster.sql.gz" ]; then
        has_cluster=true
        ((file_count++))
    fi

    if [ -f "$folder/postgres_globals.sql.gz" ]; then
        has_globals=true
        ((file_count++))
    fi

    # Count individual database backups
    local db_count=$(find "$folder" -name "postgres_db_*.sql.gz" 2>/dev/null | wc -l)
    file_count=$((file_count + db_count))

    if [ $file_count -eq 0 ]; then
        echo "empty"
    elif [ "$has_cluster" = true ] && [ "$has_globals" = true ]; then
        echo "complete"
    elif [ "$has_cluster" = true ]; then
        echo "partial"
    else
        echo "incomplete"
    fi
}

# List S3 backup folders
discover_s3_backups() {
    if [ "$S3_ENABLED" != "true" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ]; then
        return 1
    fi

    # Configure AWS CLI
    aws configure set aws_access_key_id "$S3_ACCESS_KEY" 2>/dev/null
    aws configure set aws_secret_access_key "$S3_SECRET_KEY" 2>/dev/null
    aws configure set default.region "$S3_REGION" 2>/dev/null

    # List backup folders
    aws s3 ls "s3://${S3_BUCKET}/postgres-backups/" --endpoint-url="$S3_ENDPOINT" 2>/dev/null | \
        grep "PRE" | \
        awk '{print $2}' | \
        sed 's/\///' | \
        sort -r
}

# Count S3 backups
count_s3_backups() {
    discover_s3_backups 2>/dev/null | wc -l
}

# Test S3 connectivity
test_s3_connection() {
    if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ]; then
        return 1
    fi

    aws configure set aws_access_key_id "$S3_ACCESS_KEY" 2>/dev/null
    aws configure set aws_secret_access_key "$S3_SECRET_KEY" 2>/dev/null
    aws configure set default.region "$S3_REGION" 2>/dev/null

    aws s3 ls "s3://${S3_BUCKET}/" --endpoint-url="$S3_ENDPOINT" >/dev/null 2>&1
}

# List remote (rsync) backup folders
discover_remote_backups() {
    if [ "$RSYNC_ENABLED" != "true" ] || [ -z "$RSYNC_HOST" ] || [ -z "$RSYNC_USER" ] || [ -z "$RSYNC_PATH" ]; then
        return 1
    fi

    local rsync_port="${RSYNC_PORT:-22}"

    ssh -p "$rsync_port" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "${RSYNC_USER}@${RSYNC_HOST}" \
        "find ${RSYNC_PATH} -maxdepth 1 -type d -name '20*' 2>/dev/null" 2>/dev/null | \
        xargs -n1 basename 2>/dev/null | \
        sort -r
}

# Count remote backups
count_remote_backups() {
    discover_remote_backups 2>/dev/null | wc -l
}

# Test remote connectivity
test_remote_connection() {
    if [ -z "$RSYNC_HOST" ] || [ -z "$RSYNC_USER" ]; then
        return 1
    fi

    local rsync_port="${RSYNC_PORT:-22}"

    ssh -p "$rsync_port" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "${RSYNC_USER}@${RSYNC_HOST}" \
        "exit" >/dev/null 2>&1
}

# Display available backup sources
show_backup_sources() {
    echo ""
    echo "======================================"
    echo "  Backup Sources Detection"
    echo "======================================"
    echo ""

    local sources_found=0

    # Check local
    local local_count=$(count_local_backups "/backups")
    if [ "$local_count" -gt 0 ]; then
        log_success "Local: $local_count backup(s) found in /backups"
        sources_found=$((sources_found + 1))
    else
        log_warn "Local: No backups found in /backups"
    fi

    # Check S3
    if test_s3_connection 2>/dev/null; then
        local s3_count=$(count_s3_backups)
        log_success "S3: Connected to ${S3_BUCKET} ($s3_count backup(s))"
        sources_found=$((sources_found + 1))
    else
        log_warn "S3: Not configured or not accessible"
    fi

    # Check remote
    if test_remote_connection 2>/dev/null; then
        local remote_count=$(count_remote_backups)
        log_success "Remote: Connected to ${RSYNC_USER}@${RSYNC_HOST} ($remote_count backup(s))"
        sources_found=$((sources_found + 1))
    else
        log_warn "Remote: Not configured or not accessible"
    fi

    echo ""

    if [ $sources_found -eq 0 ]; then
        log_error "No backup sources available!"
        return 1
    fi

    return 0
}
