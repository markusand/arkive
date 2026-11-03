#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for script in \
    "$ROOT/install.sh" \
    "$ROOT/setup/install.sh" \
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

# systemd-analyze verify also checks ExecStart paths on the current host; those paths
# are intentionally installed only on the target Pi, so unit validation is done there.

if grep -RniE 'nomad|/srv/nomad|nomadftp' "$ROOT" --exclude=check.sh; then
    echo 'FAIL legacy Nomad references remain.' >&2
    exit 1
fi
printf 'PASS clean Arkive naming\n'
