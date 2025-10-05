#!/bin/bash
# PostgreSQL Interactive Restore Tool

set -e

# Load helper libraries
source /lib/backup-discovery.sh
source /lib/backup-download.sh
source /lib/restore-executor.sh

# Banner
show_banner() {
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║  PostgreSQL Interactive Restore Tool  ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
}

# Main menu
show_main_menu() {
    echo ""
    echo "Main Menu:"
    echo "----------"
    echo "1. List and restore from Local backups"
    echo "2. List and restore from S3 backups"
    echo "3. List and restore from Remote backups"
    echo "4. Show all backup sources"
    echo "5. Test PostgreSQL connection"
    echo "6. Exit"
    echo ""
}

# Select backup from list
select_backup() {
    local source="$1"
    local backups=()

    case "$source" in
        local)
            mapfile -t backups < <(discover_local_backups "/backups")
            ;;
        s3)
            mapfile -t backups < <(discover_s3_backups)
            ;;
        remote)
            mapfile -t backups < <(discover_remote_backups)
            ;;
    esac

    if [ ${#backups[@]} -eq 0 ]; then
        log_error "No backups found in $source"
        return 1
    fi

    echo ""
    echo "Available backups:"
    echo "------------------"

    local i=1
    for backup in "${backups[@]}"; do
        if [ "$source" = "local" ]; then
            local folder="/backups/$backup"
            local size=$(get_backup_size "$folder")
            local age=$(get_backup_age "$folder")
            local status=$(verify_backup_folder "$folder")
            echo "$i. $backup - $size - $age ago [$status]"
        else
            echo "$i. $backup"
        fi
        ((i++))
    done

    echo ""
    read -p "Select backup number (or 0 to cancel): " selection

    if [ "$selection" -eq 0 ] 2>/dev/null; then
        return 1
    fi

    if [ "$selection" -gt 0 ] 2>/dev/null && [ "$selection" -le ${#backups[@]} ]; then
        local selected_backup="${backups[$((selection-1))]}"
        echo "$selected_backup"
        return 0
    else
        log_error "Invalid selection"
        return 1
    fi
}

# Select restore type
select_restore_type() {
    local backup_folder="$1"

    echo ""
    echo "Restore Options:"
    echo "----------------"

    local options=()

    if [ -f "$backup_folder/postgres_cluster.sql.gz" ]; then
        options+=("cluster")
        echo "${#options[@]}. Full Cluster Restore (all databases + roles)"
    fi

    if [ -f "$backup_folder/postgres_globals.sql.gz" ]; then
        options+=("globals")
        echo "${#options[@]}. Globals Only (users/roles/permissions)"
    fi

    # List available databases
    local databases=($(list_backup_databases "$backup_folder"))
    if [ ${#databases[@]} -gt 0 ]; then
        for db in "${databases[@]}"; do
            options+=("database:$db")
            echo "${#options[@]}. Database: $db"
        done
    fi

    options+=("dry-run")
    echo "${#options[@]}. Dry Run (show what would be restored)"

    options+=("cancel")
    echo "${#options[@]}. Cancel"

    echo ""
    read -p "Select restore option: " selection

    if [ "$selection" -gt 0 ] 2>/dev/null && [ "$selection" -le ${#options[@]} ]; then
        echo "${options[$((selection-1))]}"
        return 0
    else
        log_error "Invalid selection"
        return 1
    fi
}

# Process restore
process_restore() {
    local source="$1"

    # Select backup
    local backup_name=$(select_backup "$source")
    if [ -z "$backup_name" ]; then
        return 1
    fi

    echo ""
    log_info "Selected backup: $backup_name"

    # Get backup folder (download if needed)
    local backup_folder=$(get_backup_folder "$source" "$backup_name")
    if [ -z "$backup_folder" ]; then
        return 1
    fi

    # Verify integrity
    echo ""
    if ! verify_backup_integrity "$backup_folder"; then
        log_error "Backup integrity check failed!"
        read -p "Continue anyway? (yes/no): " continue_anyway
        if [ "$continue_anyway" != "yes" ]; then
            return 1
        fi
    fi

    # List backup contents
    list_backup_files "$backup_folder"

    # Select restore type
    local restore_option=$(select_restore_type "$backup_folder")
    if [ -z "$restore_option" ]; then
        return 1
    fi

    case "$restore_option" in
        cluster)
            echo ""
            if ! test_postgres_connection; then
                log_error "Cannot proceed without PostgreSQL connection"
                return 1
            fi
            restore_cluster "$backup_folder"
            if [ $? -eq 0 ]; then
                verify_restore "cluster"
            fi
            ;;
        globals)
            echo ""
            if ! test_postgres_connection; then
                log_error "Cannot proceed without PostgreSQL connection"
                return 1
            fi
            restore_globals "$backup_folder"
            if [ $? -eq 0 ]; then
                verify_restore "globals"
            fi
            ;;
        database:*)
            local db_name="${restore_option#database:}"
            echo ""
            if ! test_postgres_connection; then
                log_error "Cannot proceed without PostgreSQL connection"
                return 1
            fi
            restore_database "$backup_folder" "$db_name"
            if [ $? -eq 0 ]; then
                verify_restore "database" "$db_name"
            fi
            ;;
        dry-run)
            echo ""
            read -p "Select restore type for dry run (cluster/globals/database): " dry_type
            if [ "$dry_type" = "database" ]; then
                local dbs=($(list_backup_databases "$backup_folder"))
                echo "Available databases: ${dbs[*]}"
                read -p "Enter database name: " db_name
                dry_run_restore "$backup_folder" "database" "$db_name"
            else
                dry_run_restore "$backup_folder" "$dry_type"
            fi
            ;;
        cancel)
            log_info "Cancelled"
            return 0
            ;;
    esac

    echo ""
    read -p "Press Enter to continue..."
}

# Main loop
main() {
    show_banner

    # Check for non-interactive mode
    if [ -n "$RESTORE_SOURCE" ] && [ -n "$RESTORE_FOLDER" ] && [ -n "$RESTORE_TYPE" ]; then
        log_info "Running in non-interactive mode"
        log_info "Source: $RESTORE_SOURCE"
        log_info "Folder: $RESTORE_FOLDER"
        log_info "Type: $RESTORE_TYPE"

        local backup_folder=$(get_backup_folder "$RESTORE_SOURCE" "$RESTORE_FOLDER")
        if [ -z "$backup_folder" ]; then
            exit 1
        fi

        verify_backup_integrity "$backup_folder" || exit 1
        test_postgres_connection || exit 1

        case "$RESTORE_TYPE" in
            cluster)
                restore_cluster "$backup_folder" || exit 1
                verify_restore "cluster"
                ;;
            globals)
                restore_globals "$backup_folder" || exit 1
                verify_restore "globals"
                ;;
            database)
                if [ -z "$RESTORE_DATABASE" ]; then
                    log_error "RESTORE_DATABASE must be set for database restore"
                    exit 1
                fi
                restore_database "$backup_folder" "$RESTORE_DATABASE" || exit 1
                verify_restore "database" "$RESTORE_DATABASE"
                ;;
        esac

        log_success "Restore completed successfully"
        exit 0
    fi

    # Interactive mode
    while true; do
        show_main_menu
        read -p "Select option: " option

        case "$option" in
            1)
                process_restore "local"
                ;;
            2)
                process_restore "s3"
                ;;
            3)
                process_restore "remote"
                ;;
            4)
                show_backup_sources
                echo ""
                read -p "Press Enter to continue..."
                ;;
            5)
                echo ""
                test_postgres_connection
                echo ""
                read -p "Press Enter to continue..."
                ;;
            6)
                echo ""
                log_info "Goodbye!"
                echo ""
                exit 0
                ;;
            *)
                log_error "Invalid option"
                ;;
        esac
    done
}

# Run main
main
