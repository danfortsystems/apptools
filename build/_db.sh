#!/usr/bin/env bash

# Database build script for DBMS
# Generates database initialization and migration scripts

# Set exit on error
set -e

# Default values
dest_folder_path=""
db_url="$DATABASE_URL"
db_path="$DB_PATH"
db_reset_ok=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --db-url)
            db_url="$2"
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
            # Positional argument - destination folder path
            if [[ -z "$dest_folder_path" ]]; then
                dest_folder_path="$1"
            else
                echo "Error: Too many arguments"
                echo "Usage: _db.sh <dest_folder_path> [--db-url url] [--db-path path] [--db-reset-ok]"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$dest_folder_path" ]]; then
    echo "Error: Destination folder path is required"
    echo "Usage: _db.sh <dest_folder_path> [--db-url url] [--db-path path] [--db-reset-ok]"
    exit 1
fi

# Check if we have either PostgreSQL or SQLite configuration
if [[ -z "$db_url" && -z "$db_path" ]]; then
    echo "Warning: Neither DATABASE_URL nor DB_PATH is set. Skipping database build."
    exit 0
fi

# Define paths
init_script_path="$dest_folder_path/db.init.sql"
migra_script_path="$dest_folder_path/db.migrate.sql"
schema_scripts_folder_path="./source/server/dbms"
src_migra_script_path="$schema_scripts_folder_path/.migrate.sql"
schema_name="public"

echo "Db Build args: dest=$dest_folder_path, db-url=$db_url, db-reset-ok=$db_reset_ok"

# Create output directory
mkdir -p "$dest_folder_path"

# Remove existing output scripts
rm -f "$init_script_path" "$migra_script_path" 2>/dev/null || true

# Verify schema scripts directory exists
if [[ ! -d "$schema_scripts_folder_path" ]]; then
    echo "Error: Schema SQL scripts directory not found at $schema_scripts_folder_path"
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
    local ordered_script_paths=("$@")
    local output_script_path="$2"

    echo "Generating db init script..."

    # Create preamble with placeholder
    echo "SET search_path TO :schema;" > "$output_script_path"

    # Append each SQL file with marker
    for script_path in "${ordered_script_paths[@]}"; do
        local file_name=$(basename "$script_path")
        echo -e "\n-- FILE: $file_name\n-- PATH: $script_path" >> "$output_script_path"
        cat "$script_path" >> "$output_script_path"
    done

    echo -e "\n" >> "$output_script_path"
    echo "Done generating db init script"
}

# Check if schema has data
schema_has_data() {
    local schema="$1"
    local db_url="$2"

    # Check if any tables exist
    local tables_query="SELECT table_name FROM information_schema.tables WHERE table_schema = '$schema' AND table_type = 'BASE TABLE' LIMIT 5"
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

# Execute SQL query
exec_query() {
    local query="$1"
    local db_url="$2"
    psql "$db_url" -t -c "$query"
}

# Execute SQL script
exec_script() {
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

# Create temp schema from scripts
create_schema_from_scripts() {
	local -n ordered_script_paths=$1
    local schema=$2
    local db_url=$3

    # local ordered_script_paths=("$@")
    # local schema="$2"
    # local db_url="$3"
    local temp_script_path="/tmp/temp-schema-$$.sql"

    # Create temporary init script
    create_init_script "${ordered_script_paths[@]}" "$temp_script_path"

    # Create the schema in the db
    echo "Creating schema \"$schema\"..."
    exec_query "CREATE SCHEMA \"$schema\";" "$db_url"

    # Initialize schema with the script
    echo "Initializing schema \"$schema\"..."
    exec_script "$temp_script_path" "$schema" "$db_url"

    # Clean up temp file
    rm -f "$temp_script_path"
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

    local tables1=$(psql "$db_url" -t -c "$get_table_struct" 2>/dev/null | grep -v '^$' | sort)

	# Apply the same query for schema2
    local tables2=$(echo "$get_table_struct" | sed "s/\$1/$2/" | psql "$db_url" -t -c - 2>/dev/null | grep -v '^$' | sort)

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
    local views1=$(psql "$db_url" -t -c "SELECT view_name, view_definition FROM information_schema.views WHERE table_schema = '$schema1'" 2>/dev/null | grep -v '^$' | sort)
    local views2=$(psql "$db_url" -t -c "SELECT view_name, view_definition FROM information_schema.views WHERE table_schema = '$schema2'" 2>/dev/null | grep -v '^$' | sort)

    if [[ "$views1" != "$views2" ]]; then
        echo "Schema differences detected in views"
        diff_found=true
    fi

    # Check functions (signatures only)
    local funcs1=$(psql "$db_url" -t -c "SELECT routine_name || '(' || string_agg(parameter_name || ':' || data_type, ',') || ')'
        FROM information_schema.routines
        WHERE routine_schema = '$schema1' AND routine_type = 'FUNCTION'
        GROUP BY routine_name" 2>/dev/null | grep -v '^$' | sort)
    local funcs2=$(psql "$db_url" -t -c "SELECT routine_name || '(' || string_agg(parameter_name || ':' || data_type, ',') || ')'
        FROM information_schema.routines
        WHERE routine_schema = '$schema2' AND routine_type = 'FUNCTION'
        GROUP BY routine_name" 2>/dev/null | grep -v '^$' | sort)

    if [[ "$funcs1" != "$funcs2" ]]; then
        echo "Schema differences detected in functions"
        diff_found=true
    fi

    # Check indexes
    local indexes1=$(psql "$db_url" -t -c "SELECT indexname || ':' || indexdef
        FROM pg_indexes
        WHERE schemaname = '$schema1'" 2>/dev/null | grep -v '^$' | sort)
    local indexes2=$(psql "$db_url" -t -c "SELECT indexname || ':' || indexdef
        FROM pg_indexes
        WHERE schemaname = '$schema2'" 2>/dev/null | grep -v '^$' | sort)

    if [[ "$indexes1" != "$indexes2" ]]; then
        echo "Schema differences detected in indexes"
        diff_found=true
    fi

    [[ "$diff_found" == true ]] && return 1 || return 0
}

# Main build process
main() {
    local sorted_sql_paths=($(get_sorted_script_paths "$schema_scripts_folder_path"))

    # Generate init script
    create_init_script "${sorted_sql_paths[@]}" "$init_script_path"

    # Check if schema has data
    if schema_has_data "$schema_name" "$db_url"; then
        echo "Target schema has data; needs structural comparison with scripts"

        local temp_schema="temp_db_build_$$"

        # Create temp schema from scripts
		create_schema_from_scripts sorted_sql_paths "$temp_schema" "$db_url"
        # create_schema_from_scripts "${sorted_sql_paths[@]}" "$temp_schema" "$db_url"

        # Compare schemas
        if ! compare_schemas "$schema_name" "$temp_schema" "$db_url"; then
            echo "Existing Db Schema does not match DDL scripts."
            echo "Checking for migration script..."

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
            echo "Existing Db Schema is compatible with DDL scripts. Nothing to do."
        fi

        # Cleanup temp schema
        exec_query "DROP SCHEMA IF EXISTS \"$temp_schema\" CASCADE;" "$db_url" || true
    else
        echo "Target schema has no data; can be safely reset"
        cp "$init_script_path" "$migra_script_path"
    fi
}

# Run main function
main