# Database migrations

Arkive tracks the SQLite schema with PRAGMA user_version.

- setup/schema.sql is the immutable version 1 baseline for databases created before versioned migrations.
- Add each subsequent change as the next sequential file: NNN_short_description.sql.
- Migration files contain SQL statements only. The runner wraps each file and its version update in one BEGIN IMMEDIATE transaction.
- Never edit an already released migration. Add a new migration instead.
- Keep migrations compatible with the existing content tables; do not drop or recreate user data as part of a schema change.

The installer runs setup/migrate.sh on every installation or upgrade. Existing version-0 databases are recognized and baselined only when their documents table has the complete version 1 column set. Unknown or incomplete databases are left untouched and cause the installer to stop.
