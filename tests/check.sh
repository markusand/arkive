#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for script in \
    "$ROOT/install.sh" \
    "$ROOT/setup/install.sh" \
    "$ROOT/setup/migrate.sh" \
    "$ROOT/setup/indexer.sh" \
    "$ROOT/setup/zim-manager.sh" \
    "$ROOT/setup/arkive-search.sh" \
    "$ROOT/setup/ap-interface.sh" \
    "$ROOT/setup/sync-ap-channel.sh"; do
    bash -n "$script"
done
printf 'PASS shell syntax\n'

actual=$(printf '%s\n' 'trànsit! primers-auxilis, 123' | jq -Rr 'scan("[\\p{L}\\p{N}]+")')
expected=$'trànsit\nprimers\nauxilis\n123'
[[ "$actual" == "$expected" ]]
printf 'PASS Unicode/punctuation tokenization\n'

if command -v node >/dev/null 2>&1; then
    python3 - "$ROOT" <<'PYJS'
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
for html_path in root.glob('site/**/*.html'):
    html = html_path.read_text(encoding='utf-8')
    for script in re.findall(r'<script>(.*?)</script>', html, flags=re.DOTALL):
        with tempfile.NamedTemporaryFile('w', suffix='.js', encoding='utf-8') as temporary:
            temporary.write(script)
            temporary.flush()
            subprocess.run(['node', '--check', temporary.name], check=True)
print('PASS embedded JavaScript syntax')
PYJS
fi

python3 - "$ROOT/setup/schema.sql" <<'PY'
import sqlite3
import sys
from pathlib import Path

schema_path = Path(sys.argv[1])
connection = sqlite3.connect(':memory:')
connection.executescript(schema_path.read_text())

connection.execute(
    "INSERT INTO documents(file_path,file_name,file_type,category,title,file_size,modified_at,indexed_at) "
    "VALUES('/docs/primers.pdf','primers.pdf','pdf','reference','Primers auxilis en accidents de trànsit',1,1,1)"
)

for query in ('transit', 'trànsit', 'TRÀNSIT'):
    result = connection.execute(
        'SELECT COUNT(*) FROM documents_search WHERE documents_search MATCH ?',
        (f'"{query}"*',),
    ).fetchone()[0]
    assert result == 1, (query, result)

connection.execute(
    "UPDATE documents SET title='Primers auxilis' WHERE file_path='/docs/primers.pdf'"
)
assert connection.execute(
    "SELECT COUNT(*) FROM documents_search WHERE documents_search MATCH 'trànsit*'"
).fetchone()[0] == 0
assert connection.execute(
    "SELECT COUNT(*) FROM documents_search WHERE documents_search MATCH 'primers*'"
).fetchone()[0] == 1

connection.execute("DELETE FROM documents WHERE file_path='/docs/primers.pdf'")
assert connection.execute(
    "SELECT COUNT(*) FROM documents_search WHERE documents_search MATCH 'primers*'"
).fetchone()[0] == 0
print('PASS SQLite FTS5 accent matching and insert/update/delete triggers')
PY


MIGRATION_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$MIGRATION_TEST_DIR"' EXIT
mkdir -p "$MIGRATION_TEST_DIR/migrations"

FRESH_DATABASE="$MIGRATION_TEST_DIR/fresh.db"
bash "$ROOT/setup/migrate.sh" "$FRESH_DATABASE" "$ROOT/setup/schema.sql" "$MIGRATION_TEST_DIR/migrations"
[[ $(sqlite3 -batch -noheader "$FRESH_DATABASE" 'PRAGMA user_version;') == '1' ]]

LEGACY_DATABASE="$MIGRATION_TEST_DIR/legacy.db"
sqlite3 -bail "$LEGACY_DATABASE" < "$ROOT/setup/schema.sql"
sqlite3 -bail "$LEGACY_DATABASE" <<'SQL'
INSERT INTO documents(file_path,file_name,file_type,category,title,file_size,modified_at,indexed_at)
VALUES('/docs/preserved.pdf','preserved.pdf','pdf','reference','Preserved document',12,10,10);
SQL
bash "$ROOT/setup/migrate.sh" "$LEGACY_DATABASE" "$ROOT/setup/schema.sql" "$MIGRATION_TEST_DIR/migrations"
[[ $(sqlite3 -batch -noheader "$LEGACY_DATABASE" 'PRAGMA user_version;') == '1' ]]
[[ $(sqlite3 -batch -noheader "$LEGACY_DATABASE" 'SELECT COUNT(*) FROM documents WHERE file_path="/docs/preserved.pdf";') == '1' ]]

cat > "$MIGRATION_TEST_DIR/migrations/002_add_source_checksum.sql" <<'SQL'
ALTER TABLE documents ADD COLUMN source_checksum TEXT;
SQL
bash "$ROOT/setup/migrate.sh" "$FRESH_DATABASE" "$ROOT/setup/schema.sql" "$MIGRATION_TEST_DIR/migrations"
[[ $(sqlite3 -batch -noheader "$FRESH_DATABASE" 'PRAGMA user_version;') == '2' ]]
[[ $(sqlite3 -batch -noheader "$FRESH_DATABASE" "SELECT COUNT(*) FROM pragma_table_info('documents') WHERE name='source_checksum';") == '1' ]]

# Re-running the same installer must not reapply an already recorded migration.
bash "$ROOT/setup/migrate.sh" "$FRESH_DATABASE" "$ROOT/setup/schema.sql" "$MIGRATION_TEST_DIR/migrations"
[[ $(sqlite3 -batch -noheader "$FRESH_DATABASE" 'PRAGMA user_version;') == '2' ]]

cat > "$MIGRATION_TEST_DIR/migrations/003_forced_failure.sql" <<'SQL'
CREATE TABLE migration_rollback_probe(id INTEGER);
INSERT INTO table_that_does_not_exist VALUES(1);
SQL
if bash "$ROOT/setup/migrate.sh" "$FRESH_DATABASE" "$ROOT/setup/schema.sql" "$MIGRATION_TEST_DIR/migrations" >/dev/null 2>&1; then
    echo 'FAIL a broken migration unexpectedly succeeded.' >&2
    exit 1
fi
[[ $(sqlite3 -batch -noheader "$FRESH_DATABASE" 'PRAGMA user_version;') == '2' ]]
[[ $(sqlite3 -batch -noheader "$FRESH_DATABASE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='migration_rollback_probe';") == '0' ]]
printf 'PASS versioned SQLite migrations, legacy database preservation, idempotency and rollback\n'

# systemd-analyze verify also checks ExecStart paths on the current host; those paths
# are intentionally installed only on the target Pi, so unit validation is done there.

if grep -RniE 'nomad|/srv/nomad|nomadftp' "$ROOT" --exclude=check.sh; then
    echo 'FAIL legacy Nomad references remain.' >&2
    exit 1
fi
printf 'PASS clean Arkive naming\n'
