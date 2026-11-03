PRAGMA journal_mode = DELETE;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY,
    file_path TEXT NOT NULL UNIQUE,
    file_name TEXT NOT NULL,
    file_type TEXT NOT NULL CHECK (file_type IN ('pdf', 'txt', 'md')),
    category TEXT NOT NULL CHECK (category IN ('manuals', 'books', 'reference')),
    title TEXT NOT NULL,
    author TEXT,
    organization TEXT,
    coordinator TEXT,
    description TEXT,
    summary TEXT,
    keywords TEXT,
    topics TEXT,
    language TEXT NOT NULL DEFAULT 'und',
    page_count INTEGER,
    file_size INTEGER NOT NULL,
    modified_at INTEGER NOT NULL,
    indexed_at INTEGER NOT NULL,
    enrichment_source TEXT NOT NULL DEFAULT 'local',
    enrichment_status TEXT NOT NULL DEFAULT 'success'
        CHECK (enrichment_status IN ('success', 'failed')),
    enriched_at INTEGER
);

CREATE VIRTUAL TABLE IF NOT EXISTS documents_search USING fts5(
    title,
    author,
    organization,
    coordinator,
    description,
    summary,
    keywords,
    topics,
    content='documents',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
    INSERT INTO documents_search(
        rowid, title, author, organization, coordinator,
        description, summary, keywords, topics
    ) VALUES (
        new.id, new.title, new.author, new.organization, new.coordinator,
        new.description, new.summary, new.keywords, new.topics
    );
END;

CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
    INSERT INTO documents_search(
        documents_search, rowid, title, author, organization, coordinator,
        description, summary, keywords, topics
    ) VALUES (
        'delete', old.id, old.title, old.author, old.organization, old.coordinator,
        old.description, old.summary, old.keywords, old.topics
    );
END;

CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
    INSERT INTO documents_search(
        documents_search, rowid, title, author, organization, coordinator,
        description, summary, keywords, topics
    ) VALUES (
        'delete', old.id, old.title, old.author, old.organization, old.coordinator,
        old.description, old.summary, old.keywords, old.topics
    );
    INSERT INTO documents_search(
        rowid, title, author, organization, coordinator,
        description, summary, keywords, topics
    ) VALUES (
        new.id, new.title, new.author, new.organization, new.coordinator,
        new.description, new.summary, new.keywords, new.topics
    );
END;

CREATE TABLE IF NOT EXISTS file_observations (
    file_path TEXT PRIMARY KEY,
    file_size INTEGER NOT NULL,
    modified_at INTEGER NOT NULL,
    first_seen INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS zim_observations (
    file_path TEXT PRIMARY KEY,
    file_size INTEGER NOT NULL,
    modified_at INTEGER NOT NULL,
    first_seen INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS documents_category_idx ON documents(category);
CREATE INDEX IF NOT EXISTS documents_modified_idx ON documents(modified_at);
