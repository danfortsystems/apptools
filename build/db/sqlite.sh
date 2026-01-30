#!/usr/bin/env bash

# SQLite database build script. 
# Generates database initialization and migration scripts.

# Usage:
	#	sqlite.sh --dest <destination> [--db-path <path>] [--db-reset-ok]

# Where:
	#	<destination> is the output directory for generated SQL scripts
	#	--db-path specifies the SQLite database file path (overrides DB_PATH)
	#	--db-reset-ok allows database reset in development

# Remarks:
	#	Generates two SQL scripts: db.init.sql (full schema) and db.migrate.sql (safe for running on existing data)
	#	Checks existing SQLite database for data before creating migration
	#	If database has data and --db-reset-ok is specified, recreates the database
	#	If database has data but --db-reset-ok is not specified, creates migration script
	#	Works with SQL files prefixed with numbers (e.g., 001_create_tables.sql)

# Examples:
	#	sqlite.sh --dest ./dist					# Build to ./dist using DB_PATH
	#	sqlite.sh --dest ./dist --db-reset-ok		# Allow reset of existing database
	#	sqlite.sh --dest ./dist --db-path ./data.db	# Use specific database file
#


# Set exit on error (including undefined variables, pipelines)
set -euo pipefail

# Load utility functions
source "$(dirname "$0")/../_utils.sh"

# Default values
dest_folder_path="./dist"
db_path="$DB_PATH"
db_reset_ok=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)
            if [[ -z "$2" ]]; then
                print_error "--dest requires a non-empty value"
                exit 1
            fi
            dest_folder_path="$2"
            shift 2
            ;;
        --db-path)
            db_path="$2"
            shift 2
            ;;
        --db-reset-ok)
            db_reset_ok=true
            shift
            ;;
        *)
            print_error "Unknown argument: $1"
            echo "Usage: sqlite.sh --dest <destination> [--db-path path] [--db-reset-ok]"
            exit 1
            ;;
    esac
done


# Check if we have SQLite configuration
if [[ -z "$db_path" ]]; then
    print_error "No database path provided. Use --db-path <path> or set DB_PATH environment variable"
    exit 1
fi

# Define paths
init_script_path="$dest_folder_path/db.init.sql"
migra_script_path="$dest_folder_path/db.migrate.sql"
schema_scripts_folder_path="./source/server/db"
src_migra_script_path="$schema_scripts_folder_path/.migrate.sql"

print_step "SQLite Build args: dest=$dest_folder_path, db-path=$db_path, db-reset-ok=$db_reset_ok"

# Create output directory
mkdir -p "$dest_folder_path"

# Remove existing output scripts
rm -f "$init_script_path" "$migra_script_path"

# Verify schema scripts directory exists
if [[ ! -d "$schema_scripts_folder_path" ]]; then
    print_error "Schema SQL scripts directory not found at $schema_scripts_folder_path"
    exit 1
fi

# Get sorted SQL script paths with proper numeric prefix sorting
get_sorted_script_paths() {
    local scripts_folder="$1"
    local files=()

    # Find all SQL files except migration script
    while IFS= read -r -d $'\0' file; do
        files+=("$file")
    done < <(find "$scripts_folder" -name "*.sql" ! -name ".migrate.sql" -print0)

    # Sort by numeric prefix in filename
    printf "%s\n" "${files[@]}" | awk '{
        match($0, /^(_?)([0-9]+)/, arr)
        num = (arr[2] == "") ? 999 : arr[2]
        printf "%04d %s\n", num, $0
    }' | sort -n | cut -d' ' -f2- | grep -v '^$'
}

# Generate db init script (always)
create_init_script() {
    local -n ordered_script_paths=$1
    local output_script_path="$2"

    print_step "Generating SQLite db init script..."

    # SQLite doesn't use schemas, so just create the file
    > "$output_script_path"

    # Append each SQL file with marker
    for script_path in "${ordered_script_paths[@]}"; do
        local file_name=$(basename "$script_path")
        echo -e "\n-- FILE: $file_name\n-- PATH: $script_path" >> "$output_script_path"
        cat "$script_path" >> "$output_script_path"
    done

    echo -e "\n" >> "$output_script_path"
    print_step "Done generating SQLite db init script"
}

# Check if SQLite database has data
sqlite_db_has_data() {
    local db_path="$1"

    if [[ ! -f "$db_path" ]]; then
        return 1
    fi

    # Get table names
    local tables=$(sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")

    if [[ -z "$tables" ]]; then
        return 1
    fi

    # Check each table for data
    while IFS= read -r table_name; do
        if [[ -n "$table_name" ]]; then
            local count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM \"$table_name\";")
            if [[ "$count" -gt 0 ]]; then
                return 0
            fi
        fi
    done <<< "$tables"

    return 1
}

# Execute SQL query for SQLite
exec_sqlite_query() {
    local query="$1"
    local db_path="$2"
    sqlite3 "$db_path" "$query"
}

# Execute SQL script for SQLite
exec_sqlite_script() {
    local script_path="$1"
    local db_path="$2"
    sqlite3 "$db_path" < "$script_path"
}

# Main build process
main() {
    local sorted_sql_paths=($(get_sorted_script_paths "$schema_scripts_folder_path"))

    # Generate init script
    create_init_script sorted_sql_paths "$init_script_path"

    # Check if database has data
    if sqlite_db_has_data "$db_path"; then
        print_step "SQLite database has data; migration needed"

        # For SQLite, if there's data and --db-reset-ok is specified, recreate
        if [[ "$db_reset_ok" = true ]]; then
            print_step "--db-reset-ok specified, recreating SQLite database"
            rm -f "$db_path"
            mkdir -p "$(dirname "$db_path")"
            sqlite3 "$db_path" ""
        else
            print_step "SQLite database has data but --db-reset-ok not specified"
            echo "Will attempt to run migration script if available"

            if [[ -f "$src_migra_script_path" ]]; then
                echo "Migration script found at $src_migra_script_path."
                echo "Appending migration script to $migra_script_path..."
                cp "$src_migra_script_path" "$migra_script_path"
            else
                echo "No migration script found, using init script"
                cp "$init_script_path" "$migra_script_path"
            fi
        fi
    else
        echo "SQLite database has no data; can be safely reset"
        cp "$init_script_path" "$migra_script_path"
    fi
}

# Run main function
main "$@"
