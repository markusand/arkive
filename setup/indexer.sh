#!/usr/bin/env bash
set -Eeuo pipefail

readonly DOCUMENTS_ROOT='/srv/arkive/site/documents'
readonly DATABASE='/srv/arkive/data/catalog.db'
readonly GEMINI_CONFIG='/srv/arkive/infrastructure/gemini.env'
readonly STABILITY_SECONDS=120
readonly MAX_TEXT_BYTES=30000
export LC_ALL=C.UTF-8

for command in sqlite3 jq pdftotext pdfinfo stat find flock readlink; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$command" >&2
        exit 1
    }
done

[[ -f "$DATABASE" ]] || { echo "Database not found: $DATABASE" >&2; exit 1; }

# Serialize the two background managers; CGI reads use a SQLite busy timeout.
exec 9>/run/lock/arkive-content.lock
flock -x 9

GEMINI_API_KEY=''
GEMINI_MODEL='gemini-3.5-flash-lite'
if [[ -f "$GEMINI_CONFIG" ]]; then
    # This file is root-owned and mode 0600; values are shell-escaped by the installer.
    source "$GEMINI_CONFIG"
fi

TEMP_DIR=$(mktemp -d /tmp/arkive-indexer.XXXXXX)
trap 'rm -rf "$TEMP_DIR"; unset GEMINI_API_KEY' EXIT

sql_quote() {
    local value=${1//\'/\'\'}
    printf "'%s'" "$value"
}

sql_nullable() {
    if [[ -z "$1" ]]; then printf 'NULL'; else sql_quote "$1"; fi
}

ftp_transfer_active() {
    local file=$1 process comm descriptor target
    for process in /proc/[0-9]*; do
        [[ -r "$process/comm" ]] || continue
        IFS= read -r comm < "$process/comm" || continue
        [[ "$comm" == 'vsftpd' ]] || continue
        for descriptor in "$process"/fd/*; do
            target=$(readlink "$descriptor" 2>/dev/null || true)
            [[ "$target" == "$file" ]] && return 0
        done
    done
    return 1
}

normalise_text() {
    jq -Rs 'gsub("\\s+"; " ") | gsub("^\\s+|\\s+$"; "")'
}

extract_document_text() {
    local file=$1 output=$2 filename extension
    filename=${file##*/}
    filename=${filename%%\?*}
    extension=${filename##*.}
    extension=${extension,,}
    case "$extension" in
        pdf)
            pdftotext -layout -f 1 -l 30 "$file" "$output" 2>/dev/null || true
            ;;
        txt|md)
            head -c "$MAX_TEXT_BYTES" "$file" > "$output"
            ;;
        *) return 1 ;;
    esac
    head -c "$MAX_TEXT_BYTES" "$output" > "$output.limited"
    mv "$output.limited" "$output"
    [[ -s "$output" ]]
}

local_metadata() {
    local file=$1 category=$2 text_file=$3 result_file=$4
    local filename title author description summary keywords page_count language

    filename=${file##*/}
    filename=${filename%%\?*}
    title=${filename%.*}
    title=${title//[_-]/ }
    author=''
    page_count=''

    if [[ "${filename##*.}" =~ ^[Pp][Dd][Ff]$ ]]; then
        local pdf_info="$TEMP_DIR/pdfinfo.txt"
        pdfinfo "$file" > "$pdf_info" 2>/dev/null || true
        title=$(awk -F: '/^Title:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$pdf_info")
        author=$(awk -F: '/^Author:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$pdf_info")
        page_count=$(awk -F: '/^Pages:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pdf_info")
        [[ "$title" != '(none)' ]] || title=''
        [[ "$author" != '(none)' ]] || author=''
    fi

    [[ -n "$title" ]] || { title=${filename%.*}; title=${title//[_-]/ }; }
    description=$(head -c 700 "$text_file" | normalise_text | jq -r '.')
    summary=$(head -c 2500 "$text_file" | normalise_text | jq -r '.')
    keywords=$(printf '%s %s' "$title" "$category" | tr '[:upper:]' '[:lower:]')
    language='und'

    jq -n \
        --arg title "$title" --arg author "$author" \
        --arg description "$description" --arg summary "$summary" \
        --arg keywords "$keywords" --arg category "$category" \
        --arg language "$language" --arg page_count "$page_count" \
        '{title:$title, author:$author, organization:null, coordinator:null,
          description:$description, summary:$summary, keywords:[$keywords],
          topics:[$category], language:$language,
          page_count:(if $page_count|test("^[0-9]+$") then ($page_count|tonumber) else null end)}' \
        > "$result_file"
}

gemini_enrich() {
    local text_file=$1 local_result=$2 result_file=$3
    local request_file="$TEMP_DIR/request.json" response_file="$TEMP_DIR/response.json" curl_config="$TEMP_DIR/curl.conf"
    local candidate="$TEMP_DIR/candidate.json" merged="$TEMP_DIR/merged.json"
    local prompt generated

    [[ -n "$GEMINI_API_KEY" ]] || return 1

    prompt=$(cat <<'PROMPT'
You are a document cataloguing assistant.

Analyse the supplied document text and return accurate metadata.

Rules:
- Detect the document's primary language.
- Write title, description, summary, keywords and topics in that language.
- Do not translate metadata into English unless the document itself is in English.
- The language field must be the ISO 639-1 code of the document's primary language.
- Return the title as it appears in the document.
- Distinguish authors, editors, coordinators and organisations.
- Do not identify a coordinator as the author unless explicitly supported.
- Only include information supported by the supplied text.
- The summary should describe the actual subject and scope.
- The description must explain what practical knowledge or information the reader will find in the document.
- Never describe the document as educational material, a course module, curriculum, guide, manual, or training resource merely to fill space.
- Never begin descriptions or summaries with phrases that classify the document, such as "This document is...", "This manual is...", "Educational material...", or their equivalents in other languages. Start directly with the subject matter.
- Never repeat the title or restate the document's intended audience.
- Avoid generic introductions such as "This document covers..." or "This manual provides...".
- Prefer concrete subjects, procedures, techniques, concepts and information actually discussed.
- If the document contains insufficient information for a meaningful description, return a concise description rather than generic filler.
- The summary must add detail beyond the description, not paraphrase it.
- Distinguish explicit content from topics inferred from a table of contents.
- Keywords should include useful search phrases, not generic filler.
- Topics should be broader subject categories.
- Do not invent missing information.
- Use null for unknown scalar fields.
- Return only JSON.

Required structure:
{
  "title": "string",
  "author": null,
  "organization": null,
  "coordinator": null,
  "language": "ISO 639-1 code",
  "description": "string",
  "summary": "string",
  "keywords": ["string"],
  "topics": ["string"]
}
PROMPT
)

    jq -n --arg prompt "$prompt" --rawfile document "$text_file" \
        '{contents:[{parts:[{text:($prompt + "\n\nDOCUMENT TEXT:\n" + $document)}]}],
          generationConfig:{responseMimeType:"application/json",temperature:0.2}}' \
        > "$request_file"

    printf 'header = \"x-goog-api-key: %s\"\n' "$GEMINI_API_KEY" > "$curl_config"
    chmod 0600 "$curl_config"
    if ! curl -q -fsS --config "$curl_config" --connect-timeout 8 --max-time 45 \
        "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent" \
        -H 'Content-Type: application/json' \
        -d "@$request_file" -o "$response_file"; then
        return 1
    fi

    generated=$(jq -r '[.candidates[0].content.parts[]?.text // empty] | join("\n")' "$response_file")
    [[ -n "$generated" ]] || return 1

    if ! printf '%s' "$generated" | jq -e '
        select(
            (type == "object") and
            (.title | type == "string" and length > 0) and
            (.description | type == "string") and
            (.summary | type == "string") and
            (.keywords | type == "array") and
            (.topics | type == "array")
        )
    ' > "$candidate"; then
        return 1
    fi

    # Keep local PDF metadata when the model omits it.
    if ! jq -s '.[0] * (.[1] | with_entries(select(.value != null and .value != "")))' \
        "$local_result" "$candidate" > "$merged"; then
        return 1
    fi
    mv "$merged" "$result_file"
}

file_is_already_indexed() {
    local path=$1 size=$2 modified=$3
    local result
    result=$(sqlite3 -cmd '.timeout 5000' -noheader "$DATABASE" \
        "SELECT COUNT(*) FROM documents WHERE file_path=$(sql_quote "$path") AND file_size=$size AND modified_at=$modified;")
    [[ "$result" == '1' ]]
}

observe_file() {
    local path=$1 size=$2 modified=$3 now=$4 first_seen
    sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" <<SQL
INSERT INTO file_observations(file_path,file_size,modified_at,first_seen)
VALUES ($(sql_quote "$path"),$size,$modified,$now)
ON CONFLICT(file_path) DO UPDATE SET
    first_seen=CASE
        WHEN file_observations.file_size=excluded.file_size
         AND file_observations.modified_at=excluded.modified_at
        THEN file_observations.first_seen
        ELSE excluded.first_seen
    END,
    file_size=excluded.file_size,
    modified_at=excluded.modified_at;
SQL
    first_seen=$(sqlite3 -cmd '.timeout 5000' -noheader "$DATABASE" \
        "SELECT first_seen FROM file_observations WHERE file_path=$(sql_quote "$path");")
    (( now - first_seen >= STABILITY_SECONDS ))
}

index_file() {
    local file=$1 category=$2
    local filename filename_for_type display_filename extension size modified now page_count
    local text_file local_json metadata_json
    local title author organization coordinator description summary keywords topics language
    local source='local' enriched_at

    [[ -f "$file" ]] || return 0
    if ftp_transfer_active "$file"; then
        echo "FTP transfer still open: ${file##*/}"
        return 0
    fi
    filename=${file##*/}
    filename_for_type=${filename%%\?*}
    display_filename=$filename_for_type
    extension=${filename_for_type##*.}
    extension=${extension,,}
    case "$extension" in pdf|txt|md) ;; *) return 0 ;; esac

    size=$(stat -c '%s' -- "$file")
    modified=$(stat -c '%Y' -- "$file")
    now=$(date +%s)

    if ! observe_file "$file" "$size" "$modified" "$now"; then
        echo "Waiting for upload to settle: $filename"
        return 0
    fi

    if file_is_already_indexed "$file" "$size" "$modified"; then
        return 0
    fi

    echo "Indexing: $filename"
    text_file="$TEMP_DIR/document.txt"
    local_json="$TEMP_DIR/local.json"
    metadata_json="$TEMP_DIR/metadata.json"

    if ! extract_document_text "$file" "$text_file"; then
        sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" <<SQL
INSERT INTO documents(file_path,file_name,file_type,category,title,file_size,modified_at,indexed_at,enrichment_source,enrichment_status)
VALUES ($(sql_quote "$file"),$(sql_quote "$filename"),$(sql_quote "$extension"),$(sql_quote "$category"),$(sql_quote "${display_filename%.*}"),$size,$modified,$now,'local','failed')
ON CONFLICT(file_path) DO UPDATE SET file_size=excluded.file_size,modified_at=excluded.modified_at,indexed_at=excluded.indexed_at,enrichment_status='failed';
SQL
        echo "No extractable text: $filename"
        return 0
    fi

    local_metadata "$file" "$category" "$text_file" "$local_json"
    cp "$local_json" "$metadata_json"
    if gemini_enrich "$text_file" "$local_json" "$metadata_json"; then
        source='gemini'
    fi

    title=$(jq -r '.title // empty' "$metadata_json")
    author=$(jq -r '.author // empty' "$metadata_json")
    organization=$(jq -r '.organization // empty' "$metadata_json")
    coordinator=$(jq -r '.coordinator // empty' "$metadata_json")
    description=$(jq -r '.description // empty' "$metadata_json")
    summary=$(jq -r '.summary // empty' "$metadata_json")
    keywords=$(jq -r '(.keywords // []) | map(select(type == "string")) | join(", ")' "$metadata_json")
    topics=$(jq -r '(.topics // []) | map(select(type == "string")) | join(", ")' "$metadata_json")
    language=$(jq -r '.language // "und"' "$metadata_json")
    page_count=$(jq -r '.page_count // empty' "$metadata_json")
    [[ "$page_count" =~ ^[0-9]+$ ]] || page_count=''
    enriched_at=$now

    sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" <<SQL
INSERT INTO documents(
    file_path,file_name,file_type,category,title,author,organization,coordinator,
    description,summary,keywords,topics,language,page_count,file_size,modified_at,
    indexed_at,enrichment_source,enrichment_status,enriched_at
) VALUES (
    $(sql_quote "$file"),$(sql_quote "$filename"),$(sql_quote "$extension"),$(sql_quote "$category"),
    $(sql_quote "$title"),$(sql_nullable "$author"),$(sql_nullable "$organization"),$(sql_nullable "$coordinator"),
    $(sql_nullable "$description"),$(sql_nullable "$summary"),$(sql_nullable "$keywords"),$(sql_nullable "$topics"),
    $(sql_quote "$language"),${page_count:-NULL},$size,$modified,$now,
    $(sql_quote "$source"),'success',$enriched_at
)
ON CONFLICT(file_path) DO UPDATE SET
    file_name=excluded.file_name,file_type=excluded.file_type,category=excluded.category,
    title=excluded.title,author=excluded.author,organization=excluded.organization,
    coordinator=excluded.coordinator,description=excluded.description,summary=excluded.summary,
    keywords=excluded.keywords,topics=excluded.topics,language=excluded.language,
    page_count=excluded.page_count,file_size=excluded.file_size,modified_at=excluded.modified_at,
    indexed_at=excluded.indexed_at,enrichment_source=excluded.enrichment_source,
    enrichment_status='success',enriched_at=excluded.enriched_at;
SQL
    echo "Indexed: $title ($source)"
}

main() {
    local category directory file

    for category in manuals books reference; do
        directory="$DOCUMENTS_ROOT/$category"
        mkdir -p "$directory"
        while IFS= read -r -d '' file; do
            index_file "$file" "$category"
        done < <(find "$directory" -type f -print0)
    done

    # Remove database rows and observations for files deleted through FTP.
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if [[ ! -f "$file" ]]; then
            sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" "DELETE FROM documents WHERE file_path=$(sql_quote "$file"); DELETE FROM file_observations WHERE file_path=$(sql_quote "$file");"
            echo "Removed deleted document: $file"
        fi
    done < <(sqlite3 -cmd '.timeout 5000' -noheader "$DATABASE" 'SELECT file_path FROM documents;')

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ -f "$file" ]] || sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" "DELETE FROM file_observations WHERE file_path=$(sql_quote "$file");"
    done < <(sqlite3 -cmd '.timeout 5000' -noheader "$DATABASE" 'SELECT file_path FROM file_observations;')

    chown root:www-data "$DATABASE"
    chmod 0640 "$DATABASE"
    echo 'Document indexing pass complete.'
}

main "$@"
