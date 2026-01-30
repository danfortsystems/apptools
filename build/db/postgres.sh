#!/usr/bin/env bash

# PostgreSQL database build script
# Generates database initialization and migration scripts

# Usage:
	# postgres.sh --dest <destination> [--db-url <url>] [--db-reset-ok]

# Where:
	#	<destination> is the output directory for generated SQL scripts
	#	--db-url specifies the PostgreSQL connection URL (overrides DATABASE_URL)
	#	--db-reset-ok allows database reset in development

# Remarks:
	#	Generates two SQL scripts: db.init.sql (full schema) and db.migrate.sql (safe for running on existing data)
	#	Compares existing database schema against SQL scripts in ./source/server/db/
	#	If differences are found, creates migration script or fails (unless --db-reset-ok)
	#	Works with SQL files prefixed with numbers (e.g., 001_create_tables.sql)

# Examples:
	#	postgres.sh --dest ./dist				# Build to ./dist using DATABASE_URL
	#	postgres.sh --dest ./dist --db-reset-ok	# Allow reset of existing database
	#	postgres.sh --dest ./dist --db-url postgres://user:pass@localhost/db	# Use specific DB URL
#


# Set exit on error (including undefined variables, pipelines)
set -euo pipefail

# Load utility functions
source "$(dirname "$0")/../_utils.sh"

# Default values
dest_folder_path="./dist"
db_url="$DATABASE_URL"
db_reset_ok=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)
            dest_folder_path="$2"
            shift 2
            ;;
        --db-url)
            db_url="$2"
            shift 2
            ;;
        --db-reset-ok)
            db_reset_ok=true
            shift
            ;;
        *)
            print_error "Unknown argument: $1"
            echo "Usage: postgres.sh --dest <destination> [--db-url url] [--db-reset-ok]"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$dest_folder_path" ]]; then
    print_error "Destination folder path is required"
    echo "Usage: postgres.sh --dest <destination> [--db-url url] [--db-reset-ok]"
    exit 1
fi

# Check if we have PostgreSQL configuration
if [[ -z "$db_url" ]]; then
    print_error "No database configuration found. Use --db-url <url> or set DATABASE_URL environment variable"
    exit 1
fi

# Define paths
init_script_path="$dest_folder_path/db.init.sql"
migra_script_path="$dest_folder_path/db.migrate.sql"
schema_scripts_folder_path="./source/server/db"
src_migra_script_path="$schema_scripts_folder_path/.migrate.sql"
schema_name="public"

print_step "Postgres Build args: dest=$dest_folder_path, db-url=$db_url, db-reset-ok=$db_reset_ok"

# Create output directory
mkdir -p "$dest_folder_path"

# Remove existing output scripts
rm -f "$init_script_path" "$migra_script_path" 2>/dev/null || true

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

    print_step "Generating PostgreSQL db init script..."

    # Create preamble with placeholder
    echo "SET search_path TO :schema;" > "$output_script_path"

    # Append each SQL file with marker
    for script_path in "${ordered_script_paths[@]}"; do
        local file_name=$(basename "$script_path")
        echo -e "\n-- FILE: $file_name\n-- PATH: $script_path" >> "$output_script_path"
        cat "$script_path" >> "$output_script_path"
    done

    echo -e "\n" >> "$output_script_path"
    print_step "Done generating PostgreSQL db init script"
}

# Check if PostgreSQL schema has data
postgres_schema_has_data() {
    local schema="$1"
    local db_url="$2"

    # Check if any tables exist
    local tables_query="SELECT table_name FROM information_schema.tables WHERE table_schema = '$schema' AND table_type = 'BASE TABLE'"
    local tables=$(psql "$db_url" -t -c "$tables_query")

    if [[ -z "$tables" ]]; then
        return 1
    fi

    # Check each table for data
    while IFS= read -r table_name; do
        if [[ -n "$table_name" ]]; then
            local count_query="SELECT EXISTS(SELECT 1 FROM \"$schema\".\"$table_name\" LIMIT 1) as has_rows"
            local has_rows=$(psql "$db_url" -t -c "$count_query")
            if [[ "$has_rows" = "t" ]]; then
                return 0
            fi
        fi
    done <<< "$tables"

    return 1
}

# Execute SQL query for PostgreSQL
exec_postgres_query() {
    local query="$1"
    local db_url="$2"

    # Test connection first
    if ! psql "$db_url" -c "SELECT 1;" >/dev/null 2>&1; then
        print_error "Cannot connect to PostgreSQL database"
        exit 1
    fi

    psql "$db_url" -t -c "$query"
}

# Execute SQL script for PostgreSQL
exec_postgres_script() {
    local script_path="$1"
    local schema="$2"
    local db_url="$3"

    psql "$db_url" \
        -X \
        -P pager=off \
        -v ON_ERROR_STOP=1 \
        -v schema="$schema" \
        -f "$script_path"
}

# Check if database is local
is_local_database() {
    local db_url="$1"

    # Extract hostname from URL
    local hostname=$(echo "$db_url" | grep -oP '://[^:@]+(?::\d+)?@[^:/]+' | cut -d@ -f2 | cut -d: -f1)

    if [[ -z "$hostname" ]]; then
        hostname=$(echo "$db_url" | grep -oP '//([^:@]+)(?::\d+)?' | cut -d/ -f3 | cut -d: -f1)
    fi

    local local_hosts=("localhost" "127.0.0.1" "::1" "0.0.0.0")

    for host in "${local_hosts[@]}"; do
        if [[ "$hostname" = "$host" ]]; then
            return 0
        fi
    done

    # Check for .local domains
    if [[ "$hostname" == *.local ]]; then
        return 0
    fi

    return 1
}

# Compare schemas - checks actual structures, views, and functions
compare_schemas() {
    local schema1="$1"
    local schema2="$2"
    local db_url="$3"
    local diff_found=false

    # Get table names and their structures (table_name:column_name:data_type:position)
    local get_table_struct="SELECT t.table_name,
        string_agg(c.column_name || ':' || c.data_type || ':' || c.ordinal_position, ',' ORDER BY c.ordinal_position)
        FROM information_schema.tables t
        LEFT JOIN information_schema.columns c ON t.table_name = c.table_name AND t.table_schema = c.table_schema
        WHERE t.table_schema = '$1' AND t.table_type = 'BASE TABLE'
        GROUP BY t.table_name"

    # Check if table structure query succeeds
    local tables1
    if ! tables1=$(psql "$db_url" -t -c "$get_table_struct" | grep -v '^$' | sort); then
        print_error "Failed to retrieve table structures for schema $schema1"
        return 1
    fi

	# Apply the same query for schema2
    local tables2
    local get_table_struct2=$(echo "$get_table_struct" | sed "s/\$1/\"$schema2\"/")
    if ! tables2=$(psql "$db_url" -t -c "$get_table_struct2" | grep -v '^$' | sort); then
        print_error "Failed to retrieve table structures for schema $schema2"
        return 1
    fi

    # Compare tables
    if [[ "$tables1" != "$tables2" ]]; then
        echo "Schema differences detected in table structures:"
        echo "--- Schema1 ($schema1) tables ---"
        echo "$tables1"
        echo "--- Schema2 ($schema2) tables ---"
        echo "$tables2"
        diff_found=true
    fi

    # Check views
    local views1=$(psql "$db_url" -t -c "SELECT view_name, view_definition FROM information_schema.views WHERE table_schema = '$schema1'" | grep -v '^$' | sort)
    local views2=$(psql "$db_url" -t -c "SELECT view_name, view_definition FROM information_schema.views WHERE table_schema = '$schema2'" | grep -v '^$' | sort)

    if [[ "$views1" != "$views2" ]]; then
        echo "Schema differences detected in views"
        diff_found=true
    fi

    # Check functions (signatures only)
    local funcs1=$(psql "$db_url" -t -c "SELECT routine_name || '(' || string_agg(parameter_name || ':' || data_type, ',') || ')'
        FROM information_schema.routines
        WHERE routine_schema = '$schema1' AND routine_type = 'FUNCTION'
        GROUP BY routine_name" | grep -v '^$' | sort)
    local funcs2=$(psql "$db_url" -t -c "SELECT routine_name || '(' || string_agg(parameter_name || ':' || data_type, ',') || ')'
        FROM information_schema.routines
        WHERE routine_schema = '$schema2' AND routine_type = 'FUNCTION'
        GROUP BY routine_name" | grep -v '^$' | sort)

    if [[ "$funcs1" != "$funcs2" ]]; then
        echo "Schema differences detected in functions"
        diff_found=true
    fi

    # Check indexes
    local indexes1=$(psql "$db_url" -t -c "SELECT indexname || ':' || indexdef
        FROM pg_indexes
        WHERE schemaname = '$schema1'" | grep -v '^$' | sort)
    local indexes2=$(psql "$db_url" -t -c "SELECT indexname || ':' || indexdef
        FROM pg_indexes
        WHERE schemaname = '$schema2'" | grep -v '^$' | sort)

    if [[ "$indexes1" != "$indexes2" ]]; then
        echo "Schema differences detected in indexes"
        diff_found=true
    fi

    [[ "$diff_found" == true ]] && return 1 || return 0
}

# Create temp schema from scripts
create_temp_schema() {
	local -n ordered_script_paths=$1
    local schema=$2
    local db_url=$3
    local temp_script_path
    # Use mktemp to create a secure temporary file
    temp_script_path=$(mktemp -t "temp-schema-XXXXXX.sql") || {
        print_error "Failed to create temporary file"
        exit 1
    }

    # Set up cleanup trap
    cleanup() {
        local exit_code=$?
        rm -f "$temp_script_path" 2>/dev/null || true
        if [[ "$exit_code" -ne 0 ]]; then
            print_error "Failed to create/initialize schema '$schema'"
        fi
        return $exit_code
    }
    trap cleanup EXIT INT TERM

    # Create temporary init script
    create_init_script ordered_script_paths "$temp_script_path"

    # Create the schema in the db
    print_step "Creating schema \"$schema\"..."
    exec_postgres_query "CREATE SCHEMA \"$schema\";" "$db_url"
    # Initialize schema with the script
    print_step "Initializing schema \"$schema\"..."
    exec_postgres_script "$temp_script_path" "$schema" "$db_url"
}

# Main build process
main() {
    # Extract database name for better error messages
    if ! db_name=$(psql -X -q -Atc 'select current_database()' "$db_url") || [[ -z "${db_name//[[:space:]]/}" ]]; then
        print_error "Could not get Postgres DB name from the database URL."
        exit 1
    fi

    local sorted_sql_paths=($(get_sorted_script_paths "$schema_scripts_folder_path"))

    # Generate init script
    create_init_script sorted_sql_paths "$init_script_path"

    # Check if schema has data
    if postgres_schema_has_data "$schema_name" "$db_url"; then
        print_step "PostgreSQL schema has data; needs structural comparison with scripts"

        local temp_schema="temp_db_build_$$"

        # Create temp schema from scripts
        create_temp_schema sorted_sql_paths "$temp_schema" "$db_url"

        # Compare schemas
        if ! compare_schemas "$schema_name" "$temp_schema" "$db_url"; then
            print_step "Existing PostgreSQL Schema does not match DDL scripts."
            print_step "Checking for migration script..."

            if [[ -f "$src_migra_script_path" ]]; then
                echo "Migration script found at $src_migra_script_path."
                echo "Appending migration script to $migra_script_path..."

                # Create migration script with placeholder preamble
                echo "SET search_path TO :schema;" > "$migra_script_path"
                cat "$src_migra_script_path" >> "$migra_script_path"
            else
                echo "Migration script not found/readable at $src_migra_script_path."

                if is_local_database "$db_url"; then
                    if [[ "$db_reset_ok" = true ]]; then
                        echo "Migration script not found, but --db-reset-ok specified"
                        cp "$init_script_path" "$migra_script_path"
                    else
                        echo "Db schema differs from DDL scripts, but migration script not found."
                        echo "Use --db-reset-ok to allow database reset in development."
                        exit 1
                    fi
                else
                    echo "Db schema differs from DDL scripts, but migration script not found."
                    echo "Cannot reset remote (possibly prod) database."
                    exit 1
                fi
            fi
        else
            echo "Existing PostgreSQL Schema is compatible with DDL scripts. Nothing to do."
        fi

        # Cleanup temp schema
        exec_postgres_query "DROP SCHEMA IF EXISTS \"$temp_schema\" CASCADE;" "$db_url" || true
    else
        echo "PostgreSQL schema has no data; can be safely reset"
        cp "$init_script_path" "$migra_script_path"
    fi
}

# Run main function
main "$@"