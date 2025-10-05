#!/bin/bash
# restore-executor.sh - Execute restore operations

source /lib/backup-discovery.sh

# Test PostgreSQL connection
test_postgres_connection() {
    log_info "Testing PostgreSQL connection..."

    if [ -z "$PGHOST" ] || [ -z "$PGUSER" ]; then
        log_error "PGHOST and PGUSER must be set"
        return 1
    fi

    if psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -c "SELECT 1" >/dev/null 2>&1; then
        log_success "Connected to PostgreSQL at $PGHOST:${PGPORT:-5432}"
        return 0
    else
        log_error "Failed to connect to PostgreSQL"
        return 1
    fi
}

# Restore full cluster backup
restore_cluster() {
    local backup_folder="$1"
    local backup_file="$backup_folder/postgres_cluster.sql.gz"

    if [ ! -f "$backup_file" ]; then
        log_error "Cluster backup file not found: $backup_file"
        return 1
    fi

    log_info "Restoring full cluster from: $(basename $backup_file)"
    log_warn "This will overwrite all databases and roles"

    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Restore cancelled"
        return 1
    fi

    echo ""
    log_info "Starting cluster restore..."

    if gunzip -c "$backup_file" | psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" 2>&1 | grep -v "^$"; then
        log_success "Cluster restore completed"
        return 0
    else
        log_error "Cluster restore failed"
        return 1
    fi
}

# Restore globals only (users/roles)
restore_globals() {
    local backup_folder="$1"
    local backup_file="$backup_folder/postgres_globals.sql.gz"

    if [ ! -f "$backup_file" ]; then
        log_error "Globals backup file not found: $backup_file"
        return 1
    fi

    log_info "Restoring globals (users/roles) from: $(basename $backup_file)"

    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Restore cancelled"
        return 1
    fi

    echo ""
    log_info "Starting globals restore..."

    if gunzip -c "$backup_file" | psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" 2>&1 | grep -v "^$"; then
        log_success "Globals restore completed"
        return 0
    else
        log_error "Globals restore failed"
        return 1
    fi
}

# Restore single database
restore_database() {
    local backup_folder="$1"
    local db_name="$2"
    local backup_file="$backup_folder/postgres_db_${db_name}.sql.gz"

    if [ ! -f "$backup_file" ]; then
        log_error "Database backup file not found: $backup_file"
        return 1
    fi

    log_info "Restoring database '$db_name' from: $(basename $backup_file)"
    log_warn "This will drop and recreate the database if it exists"

    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Restore cancelled"
        return 1
    fi

    echo ""
    log_info "Starting database restore..."

    if gunzip -c "$backup_file" | psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" 2>&1 | grep -v "^$"; then
        log_success "Database restore completed"
        return 0
    else
        log_error "Database restore failed"
        return 1
    fi
}

# Verify restore
verify_restore() {
    local restore_type="$1"

    log_info "Verifying restore..."

    case "$restore_type" in
        cluster)
            # List databases
            echo ""
            echo "Databases:"
            psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -c "\l" 2>/dev/null

            # List roles
            echo ""
            echo "Roles:"
            psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -c "\du" 2>/dev/null
            ;;
        globals)
            # List roles
            echo ""
            echo "Roles:"
            psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -c "\du" 2>/dev/null
            ;;
        database)
            local db_name="$2"
            # List tables
            echo ""
            echo "Tables in '$db_name':"
            psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$db_name" -c "\dt" 2>/dev/null
            ;;
    esac

    echo ""
    log_success "Verification completed"
}

# List available databases in a backup
list_backup_databases() {
    local backup_folder="$1"

    local databases=()
    for db_file in "$backup_folder"/postgres_db_*.sql.gz; do
        if [ -f "$db_file" ]; then
            local db_name=$(basename "$db_file" | sed 's/postgres_db_//' | sed 's/.sql.gz//')
            databases+=("$db_name")
        fi
    done

    printf '%s\n' "${databases[@]}"
}

# Dry run - show what would be restored
dry_run_restore() {
    local backup_folder="$1"
    local restore_type="$2"

    echo ""
    echo "======================================"
    echo "  DRY RUN - No Changes Will Be Made"
    echo "======================================"
    echo ""
    echo "Backup folder: $(basename $backup_folder)"
    echo "Restore type: $restore_type"
    echo ""

    case "$restore_type" in
        cluster)
            if [ -f "$backup_folder/postgres_cluster.sql.gz" ]; then
                local size=$(du -h "$backup_folder/postgres_cluster.sql.gz" | cut -f1)
                echo "Would restore full cluster ($size)"
                echo "  - All databases will be restored"
                echo "  - All roles will be restored"
                echo "  - Existing data will be overwritten"
            else
                log_error "Cluster backup file not found"
                return 1
            fi
            ;;
        globals)
            if [ -f "$backup_folder/postgres_globals.sql.gz" ]; then
                local size=$(du -h "$backup_folder/postgres_globals.sql.gz" | cut -f1)
                echo "Would restore globals ($size)"
                echo "  - All roles will be restored"
                echo "  - Permissions will be restored"
            else
                log_error "Globals backup file not found"
                return 1
            fi
            ;;
        database)
            local db_name="$3"
            if [ -f "$backup_folder/postgres_db_${db_name}.sql.gz" ]; then
                local size=$(du -h "$backup_folder/postgres_db_${db_name}.sql.gz" | cut -f1)
                echo "Would restore database '$db_name' ($size)"
                echo "  - Database will be dropped and recreated"
                echo "  - All tables and data will be restored"
            else
                log_error "Database backup file not found for '$db_name'"
                return 1
            fi
            ;;
    esac

    echo ""
    echo "Target PostgreSQL: $PGHOST:${PGPORT:-5432}"
    echo "User: $PGUSER"
    echo ""

    return 0
}
