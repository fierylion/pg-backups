#!/bin/bash
# backup-download.sh - Download backups from S3 or remote server

source /lib/backup-discovery.sh

# Download backup from S3
download_from_s3() {
    local backup_folder="$1"
    local dest_dir="${2:-/restore}"

    log_info "Downloading backup from S3: $backup_folder"

    # Create destination directory
    mkdir -p "$dest_dir/$backup_folder"

    # Configure AWS CLI
    aws configure set aws_access_key_id "$S3_ACCESS_KEY" 2>/dev/null
    aws configure set aws_secret_access_key "$S3_SECRET_KEY" 2>/dev/null
    aws configure set default.region "$S3_REGION" 2>/dev/null

    local s3_path="s3://${S3_BUCKET}/postgres-backups/${backup_folder}/"

    # Download entire folder
    if aws s3 sync "$s3_path" "$dest_dir/$backup_folder/" --endpoint-url="$S3_ENDPOINT" --quiet; then
        log_success "Downloaded from S3 to $dest_dir/$backup_folder"
        echo "$dest_dir/$backup_folder"
        return 0
    else
        log_error "Failed to download from S3"
        return 1
    fi
}

# Download backup from remote server
download_from_remote() {
    local backup_folder="$1"
    local dest_dir="${2:-/restore}"

    log_info "Downloading backup from remote server: $backup_folder"

    # Create destination directory
    mkdir -p "$dest_dir/$backup_folder"

    local rsync_port="${RSYNC_PORT:-22}"
    local remote_path="${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_PATH}/${backup_folder}/"

    # Download entire folder
    if rsync -avz --quiet \
        -e "ssh -p $rsync_port -o StrictHostKeyChecking=no" \
        "$remote_path" "$dest_dir/$backup_folder/"; then
        log_success "Downloaded from remote to $dest_dir/$backup_folder"
        echo "$dest_dir/$backup_folder"
        return 0
    else
        log_error "Failed to download from remote server"
        return 1
    fi
}

# Get backup folder path (download if needed)
get_backup_folder() {
    local source="$1"
    local backup_folder="$2"
    local dest_dir="${3:-/restore}"

    case "$source" in
        local)
            local path="/backups/$backup_folder"
            if [ -d "$path" ]; then
                echo "$path"
                return 0
            else
                log_error "Local backup folder not found: $path"
                return 1
            fi
            ;;
        s3)
            download_from_s3 "$backup_folder" "$dest_dir"
            ;;
        remote)
            download_from_remote "$backup_folder" "$dest_dir"
            ;;
        *)
            log_error "Unknown source: $source"
            return 1
            ;;
    esac
}

# Verify backup integrity
verify_backup_integrity() {
    local backup_folder="$1"

    log_info "Verifying backup integrity..."

    local errors=0
    local files_checked=0

    # Check all .sql.gz files
    for file in "$backup_folder"/*.sql.gz; do
        if [ -f "$file" ]; then
            ((files_checked++))
            if gunzip -t "$file" 2>/dev/null; then
                log_success "$(basename $file) - OK"
            else
                log_error "$(basename $file) - CORRUPTED"
                ((errors++))
            fi
        fi
    done

    echo ""

    if [ $files_checked -eq 0 ]; then
        log_error "No backup files found in folder"
        return 1
    fi

    if [ $errors -gt 0 ]; then
        log_error "Found $errors corrupted file(s) out of $files_checked"
        return 1
    fi

    log_success "All $files_checked backup file(s) verified successfully"
    return 0
}

# List files in backup folder
list_backup_files() {
    local backup_folder="$1"

    echo ""
    echo "Backup contents:"
    echo "----------------"

    local has_cluster=false
    local has_globals=false
    local db_count=0

    if [ -f "$backup_folder/postgres_cluster.sql.gz" ]; then
        has_cluster=true
        local size=$(du -h "$backup_folder/postgres_cluster.sql.gz" | cut -f1)
        echo "  ✓ Full cluster backup ($size)"
    fi

    if [ -f "$backup_folder/postgres_globals.sql.gz" ]; then
        has_globals=true
        local size=$(du -h "$backup_folder/postgres_globals.sql.gz" | cut -f1)
        echo "  ✓ Globals (users/roles) ($size)"
    fi

    # List individual databases
    for db_file in "$backup_folder"/postgres_db_*.sql.gz; do
        if [ -f "$db_file" ]; then
            ((db_count++))
            local db_name=$(basename "$db_file" | sed 's/postgres_db_//' | sed 's/.sql.gz//')
            local size=$(du -h "$db_file" | cut -f1)
            echo "  ✓ Database: $db_name ($size)"
        fi
    done

    echo ""

    if [ "$has_cluster" = false ] && [ "$has_globals" = false ] && [ $db_count -eq 0 ]; then
        log_warn "No backup files found!"
        return 1
    fi

    return 0
}
