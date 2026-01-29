#!/usr/bin/env bash

# Main build script, intended to run from root of project

# Usage:
#
# 1. Full (type-check & bundle app code; generate db migration script):
# ./tools/build.sh [--dest <artifacts directory>] [--db-url <db connection url>] [--db-reset-ok]
#
# 2. Db only (Generate db migration script):
# ./tools/build.sh --only db [--dest <artifacts directory>] [--db-url <db connection url>] [--db-reset-ok]
#
# 3. App only (type-check & bundle app code; db-related args ignored):
# ./tools/build.sh --only app [--dest <artifacts directory>]

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Default values
dest_path="./dist"
db_url="$DATABASE_URL"
db_reset_ok=false
only=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)
            dest_path="$2"
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
        --only)
            only="$2"
            shift 2
            if [[ "$only" != "app" && "$only" != "db" ]]; then
                echo "Error: Invalid --only value: $only. Must be 'app' or 'db'"
                exit 1
            fi
            ;;
        *)
            echo "Error: Unknown argument: $1"
            echo "Usage: build.sh --dest <artifacts folder path> [--db-url url] [--db-reset-ok] [--only app|db]"
            exit 1
            ;;
    esac
done

# Log build arguments
echo "Build started with args: dest=$dest_path, db-url=$db_url, db-reset-ok=$db_reset_ok, only=$only"

# Type check (if not db only)
if [[ "$only" != "db" ]]; then
    echo "Type-checking..."
    pnpm exec tsc --noEmit --pretty
    echo "Type-checking completed"
fi

# Create output directories
echo "Creating directories..."
mkdir -p "$dest_path/public"

# Copy static client files (if not db only)
if [[ "$only" != "db" ]]; then
    echo "Staging static files..."
    cp -R ./source/client/static/* "$dest_path/public/"
    echo "Static files copied"
fi

# Build client-side code (if not db only)
if [[ "$only" != "db" ]]; then
    echo "Building client..."
    esbuild --entry-points './source/client/pages/**/_*.tsx' \
        --outdir "$dest_path/public" \
        --entry-names '[name]' \
        --format esm \
        --target es2020 \
        --bundle \
        --platform browser \
        --sourcemap "$([[ $NODE_ENV == 'prod' ]] && echo 'false' || echo 'true')" \
        --minify \
        --keep-names \
        --splitting \
        --tree-shaking \
        --jsx-factory createElement \
        --jsx-fragment Fragment \
        --plugins "@esbuild-plugins/node-globals-polyfill,@esbuild-plugins/node-modules-polyfill" \
        --define "process.env.NODE_ENV=\${NODE_ENV:-development}"
    echo "Client build completed"
fi

# Build server-side code (if not db only)
if [[ "$only" != "db" ]]; then
    echo "Building server..."
    esbuild --entry-points './source/server/console.ts' \
        --outfile "$dest_path/server.bundle.js" \
        --bundle \
        --format cjs \
        --target node22 \
        --platform node \
        --sourcemap "$([[ $NODE_ENV == 'prod' ]] && echo 'false' || echo 'true')" \
        --external pg-native,request,yamlparser,bun:sqlite \
        --define "process.env.NODE_ENV=production"
    echo "Server build completed"
fi

# Build database (if not app only)
if [[ "$only" != "app" ]]; then
    # Check if we have database configuration
    if [[ -n "$DATABASE_URL" ]]; then
        echo "Building PostgreSQL Database..."
        "$(dirname "$0")/_db.sh" "$dest_path" --db-url "$DATABASE_URL" --db-reset-ok "$db_reset_ok"
        echo "PostgreSQL Database build completed"
    elif [[ -n "$DB_PATH" ]]; then
        echo "Building SQLite Database..."
        "$(dirname "$0")/_db.sh" "$dest_path" --db-path "$DB_PATH" --db-reset-ok "$db_reset_ok"
        echo "SQLite Database build completed"
    else
        echo "Warning: No database configuration found (DATABASE_URL or DB_PATH not set), skipping Database build"
    fi
fi

echo "Build completed successfully"