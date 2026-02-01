#!/usr/bin/env bash

# Common database build functions for SQLite and PostgreSQL
# This file contains shared functionality used by both sqlite.sh and postgres.sh


# Get SQL script paths sorted numeric prefix
	# Finds all .sql files except .migrate.sql and sorts them by numeric prefix
	# Args:
	#   $1: Path to directory containing SQL files
	# Outputs:
	#   Prints sorted list of SQL file paths, one per line
get_sorted_script_paths() {
	local scripts_folder="$1"
	local files=()

	while IFS= read -r -d $'\0' file; do
		files+=("$file")
	done < <(find "$scripts_folder" -name "*.sql" ! -name ".migrate.sql" -print0)

	# Sort by numeric prefix using pure Bash
	local sorted=()
	for f in "${files[@]}"; do
		local base=$(basename "$f")
		# extract leading number
		if [[ $base =~ ^_?([0-9]+) ]]; then
			local num="${BASH_REMATCH[1]}"
		else
			local num=999
		fi
		sorted+=("$(printf "%04d %s" "$num" "$f")")
	done

	# sort numerically and strip prefix
	printf "%s\n" "${sorted[@]}" | sort -n | cut -d' ' -f2-
}


# Generate db init script
	# Combines multiple SQL files into a single initialization script with a custom preamble
	# Args:
	#   $1 (ref): Array of sorted SQL script paths
	#   $2: Path where the combined script should be written
	#   $3: Content to write at the beginning of the output script
create_db_init_script() {
    local -n ordered_script_paths=$1
    local output_script_path="$2"
	local preamble="${3:-}"

    # Create preamble
    echo "$preamble" > "$output_script_path"

    # Append each SQL file with marker
    for script_path in "${ordered_script_paths[@]}"; do
        local file_name=$(basename "$script_path")
        echo -e "\n-- FILE: $file_name\n-- PATH: $script_path" >> "$output_script_path"
        cat "$script_path" >> "$output_script_path"
    done

    echo -e "\n" >> "$output_script_path"
    # print_step "Done generating db init script"
}
