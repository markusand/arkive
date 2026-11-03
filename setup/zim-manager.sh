#!/usr/bin/env bash
set -Eeuo pipefail

readonly ZIM_DIR='/srv/arkive/data/zim'
readonly DATABASE='/srv/arkive/data/catalog.db'
readonly LIBRARY='/srv/arkive/data/library.xml'
readonly LIBRARY_SIGNATURE='/srv/arkive/data/zim-library.sha256'
readonly STABILITY_SECONDS=120

command -v sqlite3 >/dev/null 2>&1 || { echo 'sqlite3 is required' >&2; exit 1; }
command -v kiwix-manage >/dev/null 2>&1 || { echo 'kiwix-manage is required' >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo 'flock is required' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum is required' >&2; exit 1; }

exec 9>/run/lock/arkive-content.lock
flock -x 9

sql_quote() {
    local value=${1//\'/\'\'}
    printf "'%s'" "$value"
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

now=$(date +%s)
mkdir -p "$ZIM_DIR"
zim_files=()
while IFS= read -r -d '' candidate; do
    candidate_name=${candidate##*/}
    candidate_name=${candidate_name%%\?*}
    candidate_extension=${candidate_name##*.}
    [[ "${candidate_extension,,}" == 'zim' ]] && zim_files+=("$candidate")
done < <(find "$ZIM_DIR" -maxdepth 1 -type f -print0)

eligible=()
unstable_count=0
for zim in "${zim_files[@]}"; do
    [[ -f "$zim" ]] || continue
    if ftp_transfer_active "$zim"; then
        ((unstable_count += 1))
        echo "FTP transfer still open: ${zim##*/}"
        continue
    fi
    size=$(stat -c '%s' -- "$zim")
    modified=$(stat -c '%Y' -- "$zim")

    sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" <<SQL
INSERT INTO zim_observations(file_path,file_size,modified_at,first_seen)
VALUES ($(sql_quote "$zim"),$size,$modified,$now)
ON CONFLICT(file_path) DO UPDATE SET
    first_seen=CASE
        WHEN zim_observations.file_size=excluded.file_size
         AND zim_observations.modified_at=excluded.modified_at
        THEN zim_observations.first_seen
        ELSE excluded.first_seen
    END,
    file_size=excluded.file_size,
    modified_at=excluded.modified_at;
SQL

    first_seen=$(sqlite3 -cmd '.timeout 5000' -noheader "$DATABASE" \
        "SELECT first_seen FROM zim_observations WHERE file_path=$(sql_quote "$zim");")
    if (( now - first_seen >= STABILITY_SECONDS )); then
        eligible+=("$zim")
    else
        ((unstable_count += 1))
        echo "Waiting for ZIM upload to settle: ${zim##*/}"
    fi
done

# Drop observations for ZIM files removed through FTP.
while IFS= read -r observed; do
    [[ -n "$observed" ]] || continue
    [[ -f "$observed" ]] || sqlite3 -cmd '.timeout 5000' -bail "$DATABASE" \
        "DELETE FROM zim_observations WHERE file_path=$(sql_quote "$observed");"
done < <(sqlite3 -cmd '.timeout 5000' -noheader "$DATABASE" 'SELECT file_path FROM zim_observations;')

if (( unstable_count > 0 )); then
    echo 'At least one ZIM upload is still in progress; keeping the current library unchanged.'
    exit 0
fi

if (( ${#zim_files[@]} == 0 )); then
    rm -f "$LIBRARY" "$LIBRARY_SIGNATURE"
    systemctl disable --now arkive-kiwix.service >/dev/null 2>&1 || true
    echo 'No ZIM files remain; Kiwix stopped.'
    exit 0
fi

signature=$(
    for zim in "${eligible[@]}"; do
        printf '%s\0%s\0%s\0' "$zim" "$(stat -c '%s' -- "$zim")" "$(stat -c '%Y' -- "$zim")"
    done | sha256sum | awk '{print $1}'
)
if [[ -f "$LIBRARY" && -f "$LIBRARY_SIGNATURE" ]] && \
    [[ "$(cat "$LIBRARY_SIGNATURE")" == "$signature" ]]; then
    echo 'Kiwix library unchanged.'
    exit 0
fi

TEMP_DIR=$(mktemp -d /srv/arkive/data/.zim-library.XXXXXX)
TEMP_LIBRARY="$TEMP_DIR/library.xml"
trap 'rm -rf "$TEMP_DIR"' EXIT
added=0
failed=0
for zim in "${eligible[@]}"; do
    if kiwix-manage "$TEMP_LIBRARY" add "$zim"; then
        ((added += 1))
    else
        ((failed += 1))
        echo "Could not add ZIM (not ready or invalid): $zim" >&2
    fi
done

if (( failed > 0 || added == 0 )); then
    echo 'Library update aborted; keeping the previous library unchanged.' >&2
    exit 1
fi

chown root:www-data "$TEMP_LIBRARY"
chmod 0640 "$TEMP_LIBRARY"

was_active=0
systemctl is-active --quiet arkive-kiwix.service && was_active=1 || true
mv -f "$TEMP_LIBRARY" "$LIBRARY"
chown root:www-data "$LIBRARY"
chmod 0640 "$LIBRARY"
printf '%s\n' "$signature" > "$LIBRARY_SIGNATURE"
chown root:root "$LIBRARY_SIGNATURE"
chmod 0600 "$LIBRARY_SIGNATURE"
if (( was_active )); then
    systemctl restart arkive-kiwix.service
else
    systemctl enable --now arkive-kiwix.service
fi
echo "Kiwix library updated with $added ZIM file(s)."
