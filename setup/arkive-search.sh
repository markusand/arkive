#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C.UTF-8

DATABASE='/srv/arkive/data/catalog.db'

urldecode() {
    local input=${1//+/ }
    local output='' prefix rest hex character
    while [[ "$input" == *%* ]]; do
        prefix=${input%%\%*}
        rest=${input#*%}
        hex=${rest:0:2}
        if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
            printf -v character '%b' "\\x$hex"
            output+="$prefix$character"
            input=${rest:2}
        else
            output+="$prefix%"
            input=$rest
        fi
    done
    printf '%s%s' "$output" "$input"
}

sql_quote() {
    local escaped=${1//\'/\'\'}
    printf "'%s'" "$escaped"
}

query=''
category=''
file_type=''
IFS='&' read -ra parameters <<< "${QUERY_STRING:-}"
for parameter in "${parameters[@]}"; do
    key=${parameter%%=*}
    value=${parameter#*=}
    case "$(urldecode "$key")" in
        q) query=$(urldecode "$value") ;;
        category) category=$(urldecode "$value") ;;
        type) file_type=$(urldecode "$value") ;;
    esac
done

query=${query:0:200}
case "$category" in manuals|books|reference) ;; *) category='' ;; esac
case "$file_type" in pdf|txt|md) ;; *) file_type='' ;; esac

printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n\r\n'

if [[ -z "$query" && -z "$category" && -z "$file_type" ]]; then
    printf '[]\n'
    exit 0
fi

conditions=("d.enrichment_status = 'success'")
if [[ -n "$query" ]]; then
    fts_query=''
    mapfile -t search_terms < <(printf '%s' "$query" | jq -Rr 'scan("[\\p{L}\\p{N}]+")')
    for term in "${search_terms[@]}"; do
        [[ -n "$term" ]] || continue
        [[ -z "$fts_query" ]] || fts_query+=' AND '
        fts_query+="\"$term\"*"
    done
    if [[ -z "$fts_query" ]]; then
        printf '[]\n'
        exit 0
    fi
    conditions+=("documents_search MATCH $(sql_quote "$fts_query")")
fi

[[ -z "$category" ]] || conditions+=("d.category = $(sql_quote "$category")")
[[ -z "$file_type" ]] || conditions+=("d.file_type = $(sql_quote "$file_type")")

where_clause=''
for condition in "${conditions[@]}"; do
    [[ -z "$where_clause" ]] || where_clause+=' AND '
    where_clause+="$condition"
done

order_clause='d.title COLLATE NOCASE'
[[ -z "$query" ]] || order_clause='bm25(documents_search), d.title COLLATE NOCASE'

sql="
SELECT
    d.file_name,
    substr(d.file_path, length('/srv/arkive/site/documents/') + 1) AS relative_path,
    d.file_type,
    d.category,
    COALESCE(d.title, d.file_name) AS title,
    COALESCE(d.author, '') AS author,
    COALESCE(d.organization, '') AS organization,
    COALESCE(d.description, '') AS description,
    COALESCE(d.summary, '') AS summary,
    COALESCE(d.language, '') AS language,
    COALESCE(d.keywords, '') AS keywords
FROM documents AS d
JOIN documents_search ON documents_search.rowid = d.id
WHERE $where_clause
ORDER BY $order_clause
LIMIT 50;
"

if ! result=$(sqlite3 -cmd '.timeout 5000' -readonly -json "$DATABASE" "$sql" 2>/dev/null); then
    printf '{"error":"Search failed"}\n'
    exit 0
fi
[[ -n "$result" ]] && printf '%s\n' "$result" || printf '[]\n'
