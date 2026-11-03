#!/usr/bin/env bash
set -Eeuo pipefail

DATABASE=${1:?Usage: migrate.sh DATABASE SCHEMA_FILE MIGRATIONS_DIR}
SCHEMA_FILE=${2:?Usage: migrate.sh DATABASE SCHEMA_FILE MIGRATIONS_DIR}
MIGRATIONS_DIR=${3:?Usage: migrate.sh DATABASE SCHEMA_FILE MIGRATIONS_DIR}

die() {
    printf '[ARKIVE] Database migration failed: %s\n' "$*" >&2
    exit 1
}

[[ -r "$SCHEMA_FILE" ]] || die "Schema file is not readable: $SCHEMA_FILE"
[[ -d "$MIGRATIONS_DIR" ]] || die "Migration directory does not exist: $MIGRATIONS_DIR"
command -v sqlite3 >/dev/null 2>&1 || die 'sqlite3 is required.'

mkdir -p "$(dirname "$DATABASE")"
sqlite3 -bail "$DATABASE" 'PRAGMA journal_mode=DELETE;' >/dev/null

database_version=$(sqlite3 -batch -noheader "$DATABASE" 'PRAGMA user_version;')
[[ "$database_version" =~ ^[0-9]+$ ]] || die "Invalid database schema version: $database_version"

apply_sql_file() {
    local sql_file=$1 version=$2

    {
        printf 'PRAGMA foreign_keys=ON;\n'
        printf 'BEGIN IMMEDIATE;\n'
        cat "$sql_file"
        printf '\nPRAGMA user_version=%s;\n' "$version"
        printf 'COMMIT;\n'
    } | sqlite3 -bail "$DATABASE"
}

table_exists() {
    local table_name=$1
    [[ $(sqlite3 -batch -noheader "$DATABASE" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table_name';") == '1' ]]
}

if (( database_version == 0 )); then
    object_count=$(sqlite3 -batch -noheader "$DATABASE" \
        "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND type IN ('table','index','trigger','view');")

    if (( object_count > 0 )) && ! table_exists documents; then
        die 'The existing database is not a recognized Arkive database; refusing to modify it.'
    fi

    if table_exists documents; then
        required_columns=(
            id file_path file_name file_type category title author organization
            coordinator description summary keywords topics language page_count
            file_size modified_at indexed_at enrichment_source enrichment_status enriched_at
        )
        for column in "${required_columns[@]}"; do
            if ! sqlite3 -batch -noheader "$DATABASE" \
                "SELECT 1 FROM pragma_table_info('documents') WHERE name='$column';" | grep -qx 1; then
                die "Existing documents table is missing the '$column' column; refusing to mark it as the current baseline."
            fi
        done
    fi

    # Version 1 is the schema shipped before versioned migrations existed.
    # Applying its idempotent DDL also creates any missing indexes and triggers.
    apply_sql_file "$SCHEMA_FILE" 1
    database_version=1
fi

latest_version=$database_version
maximum_version=1
for migration_file in "$MIGRATIONS_DIR"/[0-9][0-9][0-9]_*.sql; do
    [[ -f "$migration_file" ]] || continue
    filename=${migration_file##*/}
    migration_version=${filename%%_*}
    [[ "$migration_version" =~ ^[0-9]{3}$ ]] || die "Invalid migration filename: $filename"
    (( migration_version == maximum_version + 1 )) || \
        die "Migration sequence gap: expected $(printf '%03d' "$((maximum_version + 1))"), found $filename."
    maximum_version=$migration_version
done

if (( database_version > maximum_version )); then
    die "Database schema version $database_version is newer than this installer supports ($maximum_version)."
fi

for migration_file in "$MIGRATIONS_DIR"/[0-9][0-9][0-9]_*.sql; do
    [[ -f "$migration_file" ]] || continue

    filename=${migration_file##*/}
    migration_version=${filename%%_*}
    (( migration_version > latest_version )) || continue

    expected_version=$((latest_version + 1))
    (( migration_version == expected_version )) || \
        die "Migration sequence gap: expected $(printf '%03d' "$expected_version"), found $filename."

    apply_sql_file "$migration_file" "$migration_version"
    latest_version=$migration_version
    printf '[ARKIVE] Applied database migration %s.\n' "$filename"
done

printf '[ARKIVE] Database schema is up to date (version %s).\n' "$latest_version"
