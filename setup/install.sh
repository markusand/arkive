#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly INSTALL_LOG='/var/log/arkive-install.log'
readonly BACKUP_ROOT='/root/arkive-backups'

DRY_RUN=0
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        --help)
            printf 'Usage: %s [--dry-run]\n' "$(basename "$0")"
            exit 0
            ;;
        *) printf 'Unknown option: %s\nUsage: %s [--dry-run]\n' "$argument" "$(basename "$0")" >&2; exit 2 ;;
    esac
done

umask 077
[[ $EUID -eq 0 ]] || { printf 'Run the installer as root (for example: sudo bash install.sh).\n' >&2; exit 1; }
[[ -r /dev/tty ]] || { printf 'An interactive terminal is required because the installer prompts for credentials.\n' >&2; exit 1; }
if (( ! DRY_RUN )); then
    exec > >(tee -a "$INSTALL_LOG") 2>&1
fi

log() { printf '\n[ARKIVE] %s\n' "$*"; }
die() { printf '\n[ARKIVE] ERROR: %s\n' "$*" >&2; exit 1; }


# Hardware and operating-system preflight.
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in debian|dietpi|raspbian) ;; *) die "Arkive targets DietPi/Debian/Raspbian; detected ${PRETTY_NAME:-unknown}." ;; esac
[[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "Arkive 0.1.0 targets Debian 13 Trixie; detected ${VERSION_CODENAME:-unknown}."
ARCH=$(dpkg --print-architecture)
[[ "$ARCH" == 'armhf' ]] || die "This release targets 32-bit ARM hard-float (armhf); detected $ARCH."
for network_manager in NetworkManager connman systemd-networkd; do
    if systemctl is-active --quiet "$network_manager.service"; then
        die "$network_manager is active. This installer configures the DietPi/Debian ifupdown + wpa_supplicant network stack; disable $network_manager first."
    fi
done
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
CPU_ARCH=$(uname -m)
if [[ -n "$MODEL" && "$MODEL" != *'Raspberry Pi Zero W'* ]]; then
    die "Arkive 0.1.0 targets the original Raspberry Pi Zero W; detected $MODEL."
fi
if [[ "$CPU_ARCH" != 'armv6l' ]]; then
    die "Arkive 0.1.0 targets the original ARMv6 Pi Zero W; detected CPU architecture $CPU_ARCH."
fi

# Collect and validate every setting before changing the system.
read_default() {
    local prompt=$1 default=$2 variable=$3 value
    read -r -p "$prompt [$default]: " value </dev/tty
    printf -v "$variable" '%s' "${value:-$default}"
}

read_secret() {
    local prompt=$1 variable=$2 value
    read -r -s -p "$prompt: " value </dev/tty
    printf '\n'
    printf -v "$variable" '%s' "$value"
}

validate_ssid() {
    local label=$1 value=$2 byte_length
    byte_length=$(LC_ALL=C printf '%s' "$value" | wc -c)
    [[ -n "$value" && $byte_length -le 32 ]] || die "$label must contain between 1 and 32 UTF-8 bytes."
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label contains an invalid newline."
}

printf '\n'
printf '============================================================\n'
printf '                 ARKIVE INSTALLER\n'
printf '              Knowledge. Preserved.\n'
printf '============================================================\n'
printf 'This installer configures the complete offline appliance.\n'
printf 'All settings are collected now, before system changes begin.\n\n'

read_default 'Hostname' 'arkive' HOSTNAME_VALUE
[[ "$HOSTNAME_VALUE" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die 'Invalid hostname.'

read_default 'Wi-Fi regulatory country (ISO 3166-1 alpha-2)' 'AD' WIFI_COUNTRY
WIFI_COUNTRY=${WIFI_COUNTRY^^}
[[ "$WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die 'Country must be a two-letter ISO code.'

read -r -p 'Home Wi-Fi SSID: ' WIFI_SSID </dev/tty
validate_ssid 'Home Wi-Fi SSID' "$WIFI_SSID"
read_secret 'Home Wi-Fi password (leave empty for an open network)' WIFI_PASSWORD
if [[ -n "$WIFI_PASSWORD" && ${#WIFI_PASSWORD} -lt 8 ]]; then
    die 'A WPA/WPA2 Wi-Fi password must contain at least 8 characters.'
fi
if [[ -n "$WIFI_PASSWORD" && ${#WIFI_PASSWORD} -gt 63 && ! "$WIFI_PASSWORD" =~ ^[0-9a-fA-F]{64}$ ]]; then
    die 'A WPA/WPA2 passphrase must be at most 63 characters (or a 64-digit hexadecimal PSK).'
fi

read_default 'Arkive access point SSID' 'arkive' AP_SSID
validate_ssid 'Access point SSID' "$AP_SSID"
read_secret 'Access point password (leave empty for an open access point)' AP_PASSWORD
if [[ -n "$AP_PASSWORD" && ( ${#AP_PASSWORD} -lt 8 || ${#AP_PASSWORD} -gt 63 ) ]]; then
    die 'The access point password must contain 8–63 characters.'
fi

read_default 'Access point subnet (private IPv4 /24)' '192.168.50.0/24' AP_SUBNET
if [[ ! "$AP_SUBNET" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]]; then
    die 'Access point subnet must be an IPv4 network ending in .0/24.'
fi
AP_OCTET_1=${BASH_REMATCH[1]}; AP_OCTET_2=${BASH_REMATCH[2]}; AP_OCTET_3=${BASH_REMATCH[3]}
for octet in "$AP_OCTET_1" "$AP_OCTET_2" "$AP_OCTET_3"; do
    (( 10#$octet <= 255 )) || die "Invalid IPv4 subnet: $AP_SUBNET"
done
AP_PREFIX="$((10#$AP_OCTET_1)).$((10#$AP_OCTET_2)).$((10#$AP_OCTET_3))"
if ! (( 10#$AP_OCTET_1 == 10 || (10#$AP_OCTET_1 == 172 && 10#$AP_OCTET_2 >= 16 && 10#$AP_OCTET_2 <= 31) || (10#$AP_OCTET_1 == 192 && 10#$AP_OCTET_2 == 168) )); then
    die 'The access point subnet must be in a private IPv4 range (RFC 1918).'
fi
AP_ADDRESS="$AP_PREFIX.1/24"
AP_DHCP_START="$AP_PREFIX.10"
AP_DHCP_END="$AP_PREFIX.100"

FTP_USER_DEFAULT='arkiveftp'
if [[ -f /etc/arkive/ftp-user ]]; then
    IFS= read -r FTP_USER_DEFAULT < /etc/arkive/ftp-user
fi
read_default 'FTP username' "$FTP_USER_DEFAULT" FTP_USER
if [[ -f /etc/arkive/ftp-user && "$FTP_USER" != "$FTP_USER_DEFAULT" ]]; then
    die "The FTP username is already established as $FTP_USER_DEFAULT and cannot be renamed by a re-run."
fi
[[ "$FTP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$FTP_USER" != 'root' ]] || die 'Invalid FTP username.'
if id "$FTP_USER" >/dev/null 2>&1; then
    EXISTING_FTP_HOME=$(getent passwd "$FTP_USER" | cut -d: -f6)
    [[ "$EXISTING_FTP_HOME" == '/srv/arkive/ftp' ]] || die "The account $FTP_USER already exists and is not an Arkive FTP account. Choose another username."
fi
read_secret 'FTP password (minimum 8 characters)' FTP_PASSWORD
[[ ${#FTP_PASSWORD} -ge 8 ]] || die 'FTP password must contain at least 8 characters.'
[[ "$FTP_PASSWORD" != *$'\n'* && "$FTP_PASSWORD" != *$'\r'* ]] || die 'FTP password contains an invalid newline.'

read_default 'Timezone' 'Europe/Andorra' TIMEZONE
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"

read_secret 'Gemini API key (optional; leave empty for local-only indexing)' GEMINI_API_KEY
GEMINI_MODEL='gemini-3.5-flash-lite'

# Reject any overlap with a directly connected home-LAN subnet.
ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}
while IFS= read -r HOME_ROUTE; do
    [[ "$HOME_ROUTE" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]] || continue
    HOME_NETWORK=${BASH_REMATCH[1]}
    HOME_PREFIX_LENGTH=${BASH_REMATCH[2]}
    (( HOME_PREFIX_LENGTH <= 32 )) || continue
    if (( HOME_PREFIX_LENGTH == 0 )); then
        HOME_MASK=0
    else
        HOME_MASK=$(( (0xffffffff << (32 - HOME_PREFIX_LENGTH)) & 0xffffffff ))
    fi
    HOME_NETWORK_INT=$(ipv4_to_int "$HOME_NETWORK")
    AP_TEST_INT=$(ipv4_to_int "$AP_PREFIX.1")
    if (( (HOME_NETWORK_INT & HOME_MASK) == (AP_TEST_INT & HOME_MASK) )); then
        die "The AP subnet $AP_SUBNET overlaps the connected home Wi-Fi network $HOME_ROUTE. Choose a different /24 subnet."
    fi
done < <(ip -4 route show dev wlan0 scope link 2>/dev/null | awk '{print $1}')

printf '\nInstallation settings\n'
printf '  Hostname:       %s\n' "$HOSTNAME_VALUE"
printf '  Home Wi-Fi:     %s\n' "$WIFI_SSID"
printf '  AP SSID:        %s\n' "$AP_SSID"
printf '  AP subnet:      %s (gateway %s)\n' "$AP_SUBNET" "${AP_ADDRESS%/24}"
printf '  AP channel:     automatically follows the home Wi-Fi channel\n'
printf '  FTP account:    %s\n' "$FTP_USER"
printf '  Timezone:       %s\n' "$TIMEZONE"
printf '  Gemini:         %s\n' "$([[ -n "$GEMINI_API_KEY" ]] && echo 'optional enrichment enabled' || echo 'local indexing only')"
printf '\nNo content will be downloaded. Documents and ZIM files are uploaded later through FTP.\n\n'
if (( DRY_RUN )); then
    log 'Dry-run complete: all settings passed validation; no system changes were made.'
    exit 0
fi
read -r -p 'Proceed with installation? [y/N] ' CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die 'Installation cancelled before making system changes.'

# Keep a recoverable snapshot of configuration files before changing them.
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP_ROOT" "$BACKUP_DIR"
chmod 0700 "$BACKUP_ROOT" "$BACKUP_DIR"
BACKUP_PATHS=(
    etc/fstab etc/hostname etc/hosts etc/localtime etc/timezone etc/shells
    etc/wpa_supplicant/wpa_supplicant.conf
    etc/network/interfaces etc/network/interfaces.d
    etc/lighttpd/conf-enabled/99-arkive.conf
    etc/lighttpd/conf-enabled/10-cgi.conf
    etc/vsftpd.conf
    etc/hostapd/arkive.conf
    etc/dnsmasq.d/arkive.conf
    etc/arkive/network.env etc/arkive/ftp-user
    etc/sysctl.d/99-arkive.conf
    etc/systemd/system/arkive-indexer.service
    etc/systemd/system/arkive-indexer.timer
    etc/systemd/system/arkive-zim-manager.service
    etc/systemd/system/arkive-zim-manager.timer
    etc/systemd/system/arkive-kiwix.service
    etc/systemd/system/arkive-ap-interface.service
    etc/systemd/system/arkive-hostapd.service
    etc/systemd/system/arkive-dnsmasq.service
    etc/systemd/system/arkive-ap-channel.service
    etc/systemd/system/arkive-ap-channel.timer
    etc/systemd/system/arkive-ap.target
)
tar --ignore-failed-read -cpf "$BACKUP_DIR/configuration.tar" -C / "${BACKUP_PATHS[@]}" 2>/dev/null || true
chmod 0600 "$BACKUP_DIR/configuration.tar"
hostname > "$BACKUP_DIR/hostname.before" 2>/dev/null || true
SERVICE_UNITS=(
    hostapd.service dnsmasq.service lighttpd.service vsftpd.service
    arkive-ap.target arkive-indexer.timer arkive-zim-manager.timer arkive-ap-channel.timer
    arkive-indexer.service arkive-zim-manager.service arkive-hostapd.service
    arkive-dnsmasq.service arkive-ap-interface.service arkive-kiwix.service
)
: > "$BACKUP_DIR/service-states.tsv"
for unit in "${SERVICE_UNITS[@]}"; do
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$unit" "${enabled:-not-found}" "${active:-inactive}" \
        >> "$BACKUP_DIR/service-states.tsv"
done
chmod 0600 "$BACKUP_DIR/service-states.tsv"

rollback() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
        log "Installation failed (exit $status). Restoring backed-up configuration from $BACKUP_DIR."
        umount /srv/arkive/ftp/documents/manuals /srv/arkive/ftp/documents/books \
            /srv/arkive/ftp/documents/reference /srv/arkive/ftp/zim 2>/dev/null || true
        systemctl stop lighttpd.service vsftpd.service hostapd.service dnsmasq.service 2>/dev/null || true
        systemctl disable --now arkive-ap.target arkive-indexer.timer arkive-zim-manager.timer arkive-ap-channel.timer \
            arkive-indexer.service arkive-zim-manager.service arkive-hostapd.service arkive-dnsmasq.service \
            arkive-ap-interface.service arkive-kiwix.service 2>/dev/null || true
        rm -f /etc/lighttpd/conf-enabled/99-arkive.conf /etc/lighttpd/conf-enabled/10-cgi.conf \
            /etc/vsftpd.conf /etc/hostapd/arkive.conf /etc/dnsmasq.d/arkive.conf \
            /etc/arkive/network.env /etc/arkive/ftp-user /etc/sysctl.d/99-arkive.conf \
            /etc/wpa_supplicant/wpa_supplicant.conf /etc/network/interfaces \
            /etc/hosts /etc/hostname /etc/localtime /etc/timezone /etc/shells \
            /etc/systemd/system/arkive-*.service /etc/systemd/system/arkive-*.timer \
            /etc/systemd/system/arkive-ap.target /etc/systemd/system/arkive-kiwix.service \
            /usr/lib/cgi-bin/arkive-search.sh
        tar -xpf "$BACKUP_DIR/configuration.tar" -C / 2>/dev/null || true
        if [[ -s "$BACKUP_DIR/hostname.before" ]]; then
            cp "$BACKUP_DIR/hostname.before" /etc/hostname 2>/dev/null || true
            hostname "$(cat "$BACKUP_DIR/hostname.before")" 2>/dev/null || true
        fi
        sysctl --system >/dev/null 2>&1 || true
        systemctl daemon-reload 2>/dev/null || true
        while IFS=$'\t' read -r unit enabled active; do
            case "$enabled" in
                enabled|enabled-runtime|linked|linked-runtime) systemctl enable "$unit" >/dev/null 2>&1 || true ;;
                masked) systemctl mask "$unit" >/dev/null 2>&1 || true ;;
                *) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
            esac
            if [[ "$active" == 'active' ]]; then
                systemctl start "$unit" >/dev/null 2>&1 || true
            else
                systemctl stop "$unit" >/dev/null 2>&1 || true
            fi
        done < "$BACKUP_DIR/service-states.tsv"
        log "Configuration and service states restored from $BACKUP_DIR. Installed Debian packages and the FTP account, if created, are not automatically removed."
    fi
    exit "$status"
}
trap rollback EXIT

log 'Updating package indexes and installing ARM-compatible dependencies.'
export DEBIAN_FRONTEND=noninteractive
apt-get update

if ! apt-cache show firmware-brcm80211 >/dev/null 2>&1; then
    die 'firmware-brcm80211 is unavailable. Enable the non-free-firmware APT component and run the installer again.'
fi

apt-get install -y \
    ca-certificates curl dnsmasq hostapd ifupdown iproute2 iw jq \
    firmware-brcm80211 kiwix-tools lighttpd media-types poppler-utils sqlite3 util-linux vsftpd wpasupplicant

# Confirm that the packaged SQLite build has FTS5 and the required tokenizer.
sqlite3 :memory: "CREATE VIRTUAL TABLE fts_check USING fts5(value, tokenize='unicode61 remove_diacritics 2');" >/dev/null

# Use direct file writes; hostnamectl/timedatectl require D-Bus which may not
# be available on minimal Raspbian images.
printf '%s\n' "$HOSTNAME_VALUE" > /etc/hostname
hostname "$HOSTNAME_VALUE"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
printf '%s\n' "$TIMEZONE" > /etc/timezone
iw reg set "$WIFI_COUNTRY"

if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $HOSTNAME_VALUE/" /etc/hosts
else
    printf '127.0.1.1 %s\n' "$HOSTNAME_VALUE" >> /etc/hosts
fi

log 'Creating Arkive directories and content permissions.'
getent group arkive-content >/dev/null || groupadd --system arkive-content
id -u www-data >/dev/null 2>&1 || die 'The www-data account was not created by the lighttpd package.'
usermod -aG arkive-content www-data

install -d -o root -g root -m 0711 /srv/arkive
install -d -o root -g www-data -m 0755 /srv/arkive/site
install -d -o root -g www-data -m 0755 /srv/arkive/site/documents
install -d -o root -g www-data -m 0755 /srv/arkive/site/maps
install -d -o root -g www-data -m 0755 /srv/arkive/site/wikipedia
install -d -o root -g arkive-content -m 2775 \
    /srv/arkive/site/documents/manuals \
    /srv/arkive/site/documents/books \
    /srv/arkive/site/documents/reference
install -d -o root -g www-data -m 0750 /srv/arkive/data
install -d -o root -g arkive-content -m 2775 /srv/arkive/data/zim
install -d -o root -g root -m 0700 /srv/arkive/infrastructure
install -d -o root -g root -m 0755 /srv/arkive/ftp
install -d -o root -g root -m 0755 /srv/arkive/ftp/documents
install -d -o root -g root -m 0755 \
    /srv/arkive/ftp/documents/manuals \
    /srv/arkive/ftp/documents/books \
    /srv/arkive/ftp/documents/reference \
    /srv/arkive/ftp/zim
install -d -o root -g root -m 0755 /usr/local/lib/arkive
install -d -o root -g root -m 0755 /etc/arkive

# Deploy the final site and runtime scripts. Existing user content is never removed.
install -o root -g www-data -m 0644 "$REPO_ROOT/site/index.html" /srv/arkive/site/index.html
install -o root -g www-data -m 0644 "$REPO_ROOT/site/documents/index.html" /srv/arkive/site/documents/index.html
install -o root -g www-data -m 0644 "$REPO_ROOT/site/maps/index.html" /srv/arkive/site/maps/index.html
install -o root -g www-data -m 0644 "$REPO_ROOT/site/wikipedia/index.html" /srv/arkive/site/wikipedia/index.html
install -o root -g root -m 0750 "$REPO_ROOT/setup/indexer.sh" /srv/arkive/infrastructure/indexer.sh
install -o root -g root -m 0750 "$REPO_ROOT/setup/zim-manager.sh" /srv/arkive/infrastructure/zim-manager.sh
install -o root -g root -m 0640 "$REPO_ROOT/setup/schema.sql" /srv/arkive/infrastructure/schema.sql
install -o root -g root -m 0750 "$REPO_ROOT/setup/ap-interface.sh" /usr/local/lib/arkive/ap-interface.sh
install -o root -g root -m 0750 "$REPO_ROOT/setup/sync-ap-channel.sh" /usr/local/lib/arkive/sync-ap-channel.sh

# Initialize the final database schema directly (no migration chain).
if [[ ! -f /srv/arkive/data/catalog.db ]]; then
    sqlite3 -bail /srv/arkive/data/catalog.db < /srv/arkive/infrastructure/schema.sql
fi
chown root:www-data /srv/arkive/data/catalog.db
chmod 0640 /srv/arkive/data/catalog.db
chown root:www-data /srv/arkive/data
chmod 0750 /srv/arkive/data

# Optional AI enrichment. Local extraction/indexing always works without a key.
printf 'GEMINI_API_KEY=%q\nGEMINI_MODEL=%q\n' "$GEMINI_API_KEY" "$GEMINI_MODEL" \
    > /srv/arkive/infrastructure/gemini.env
chown root:root /srv/arkive/infrastructure/gemini.env
chmod 0600 /srv/arkive/infrastructure/gemini.env
chmod 0700 /srv/arkive/infrastructure

log 'Configuring the home Wi-Fi connection and access point.'
install -d -o root -g root -m 0755 /etc/wpa_supplicant
SSID_HEX=$(printf '%s' "$WIFI_SSID" | od -An -tx1 | tr -d ' \n')
if [[ -n "$WIFI_PASSWORD" ]]; then
    if [[ "$WIFI_PASSWORD" =~ ^[0-9a-fA-F]{64}$ ]]; then
        WIFI_PSK=$WIFI_PASSWORD
    else
        WIFI_PSK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" | awk -F= '/^[[:space:]]*psk=/ {print $2; exit}')
    fi
    [[ "$WIFI_PSK" =~ ^[0-9a-fA-F]{64}$ ]] || die 'Could not derive a WPA pre-shared key from the supplied Wi-Fi password.'
    WIFI_NETWORK="    key_mgmt=WPA-PSK\n    psk=$WIFI_PSK"
else
    WIFI_NETWORK='    key_mgmt=NONE'
fi
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF_WPA
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=$WIFI_COUNTRY

network={
    ssid=$SSID_HEX
$(printf '%b\n' "$WIFI_NETWORK")
    scan_ssid=1
}
EOF_WPA
chown root:root /etc/wpa_supplicant/wpa_supplicant.conf
chmod 0600 /etc/wpa_supplicant/wpa_supplicant.conf

# Add a standard ifupdown stanza only when the image has no wlan0 definition.
WLAN_CONFIG_FILE=$(grep -RlE '^[[:space:]]*iface[[:space:]]+wlan0[[:space:]]+inet' \
    /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null | head -n 1 || true)
if [[ -z "$WLAN_CONFIG_FILE" ]]; then
    cat >> /etc/network/interfaces <<'EOF_WLAN'

# Arkive home Wi-Fi connection
allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF_WLAN
elif ! grep -Fq 'wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf' "$WLAN_CONFIG_FILE"; then
    TEMP_INTERFACES=$(mktemp)
    awk '
        /^[[:space:]]*iface[[:space:]]+wlan0[[:space:]]+inet/ { in_wlan=1; print; next }
        in_wlan && /^[[:space:]]*iface[[:space:]]+/ {
            if (!added) print "    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf"
            in_wlan=0
        }
        in_wlan && /^[[:space:]]*wpa-conf[[:space:]]/ {
            print "    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf"
            added=1
            next
        }
        { print }
        END { if (in_wlan && !added) print "    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf" }
    ' "$WLAN_CONFIG_FILE" > "$TEMP_INTERFACES"
    cat "$TEMP_INTERFACES" > "$WLAN_CONFIG_FILE"
    rm -f "$TEMP_INTERFACES"
fi
if [[ "$WLAN_CONFIG_FILE" == /etc/network/interfaces.d/* ]] && \
    ! grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces; then
    printf '\nsource /etc/network/interfaces.d/*\n' >> /etc/network/interfaces
fi

cat > /etc/arkive/network.env <<EOF_NET
AP_ADDRESS='$AP_ADDRESS'
AP_SUBNET='$AP_SUBNET'
EOF_NET
chmod 0600 /etc/arkive/network.env

cat > /etc/hostapd/arkive.conf <<EOF_HOSTAPD
interface=uap0
driver=nl80211
ssid=$AP_SSID
country_code=$WIFI_COUNTRY
ieee80211d=1
hw_mode=g
channel=1
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF_HOSTAPD
if [[ -n "$AP_PASSWORD" ]]; then
    cat >> /etc/hostapd/arkive.conf <<EOF_APSEC
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$AP_PASSWORD
EOF_APSEC
fi
chown root:root /etc/hostapd/arkive.conf
chmod 0600 /etc/hostapd/arkive.conf

cat > /etc/dnsmasq.d/arkive.conf <<EOF_DNS
port=0
interface=uap0
except-interface=wlan0
bind-interfaces
dhcp-authoritative
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,255.255.255.0,12h
dhcp-option=option:router
dhcp-option=option:dns-server
log-dhcp
EOF_DNS
chown root:root /etc/dnsmasq.d/arkive.conf
chmod 0644 /etc/dnsmasq.d/arkive.conf

# Isolated AP: DHCP only, no DNS, routing, NAT or internet forwarding.
cat > /etc/sysctl.d/99-arkive.conf <<'EOF_SYSCTL'
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
EOF_SYSCTL
sysctl --system >/dev/null

log 'Configuring the FTP account and content-only chroot.'
if ! grep -Fxq '/usr/sbin/nologin' /etc/shells; then
    printf '/usr/sbin/nologin\n' >> /etc/shells
fi
if id "$FTP_USER" >/dev/null 2>&1; then
    usermod --home /srv/arkive/ftp --shell /usr/sbin/nologin --gid arkive-content "$FTP_USER"
else
    useradd --no-create-home --home-dir /srv/arkive/ftp --shell /usr/sbin/nologin --gid arkive-content "$FTP_USER"
fi
printf '%s:%s\n' "$FTP_USER" "$FTP_PASSWORD" | chpasswd
printf '%s\n' "$FTP_USER" > /etc/arkive/ftp-user
chown root:root /etc/arkive/ftp-user
chmod 0600 /etc/arkive/ftp-user

cat > /etc/vsftpd.conf <<EOF_FTP
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=002
file_open_mode=0664
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=NO
local_root=/srv/arkive/ftp
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40010
pam_service_name=vsftpd
ssl_enable=NO
EOF_FTP
chmod 0644 /etc/vsftpd.conf

# Expose only category upload directories and the ZIM directory inside FTP.
add_bind_mount() {
    local source=$1 target=$2
    if awk -v target="$target" '$2 == target { found=1 } END { exit !found }' /etc/fstab; then
        awk -v source="$source" -v target="$target" '$1 == source && $2 == target && $3 == "none" && $4 ~ /bind/ { found=1 } END { exit !found }' /etc/fstab \
            || die "An existing /etc/fstab entry conflicts with $target. Review it before continuing."
    else
        printf '%s %s none bind 0 0\n' "$source" "$target" >> /etc/fstab
    fi
}
add_bind_mount /srv/arkive/site/documents/manuals /srv/arkive/ftp/documents/manuals
add_bind_mount /srv/arkive/site/documents/books /srv/arkive/ftp/documents/books
add_bind_mount /srv/arkive/site/documents/reference /srv/arkive/ftp/documents/reference
add_bind_mount /srv/arkive/data/zim /srv/arkive/ftp/zim
mount -a

# Make uploaded content readable by Lighttpd/Kiwix and writable by the FTP group.
chown root:arkive-content \
    /srv/arkive/site/documents/manuals \
    /srv/arkive/site/documents/books \
    /srv/arkive/site/documents/reference \
    /srv/arkive/data/zim
chmod 2775 \
    /srv/arkive/site/documents/manuals \
    /srv/arkive/site/documents/books \
    /srv/arkive/site/documents/reference \
    /srv/arkive/data/zim
chown root:root /srv/arkive/ftp
chmod 0755 /srv/arkive/ftp
chown root:root /srv/arkive/ftp/documents
chmod 0755 /srv/arkive/ftp/documents

log 'Configuring Lighttpd, Kiwix and systemd services.'
# Set the document root in the main config to avoid a duplicate-variable error
# from lighttpd when a conf-enabled fragment re-assigns server.document-root.
sed -i 's|^\(server\.document-root\s*=\s*\).*|\1"/srv/arkive/site"|' /etc/lighttpd/lighttpd.conf
# Remove the stock CGI fragment to avoid a duplicate cgi.assign declaration;
# our config below loads mod_cgi and sets the only assignment we need.
rm -f /etc/lighttpd/conf-enabled/10-cgi.conf
cat > /etc/lighttpd/conf-enabled/99-arkive.conf <<'EOF_LIGHTTPD'
server.modules += ( "mod_cgi" )
alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )
cgi.assign = ( ".sh" => "/bin/bash" )
EOF_LIGHTTPD
install -d -o root -g root -m 0755 /usr/lib/cgi-bin
install -o root -g root -m 0755 "$REPO_ROOT/setup/arkive-search.sh" /usr/lib/cgi-bin/arkive-search.sh

install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-indexer.service" /etc/systemd/system/arkive-indexer.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-indexer.timer" /etc/systemd/system/arkive-indexer.timer
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-zim-manager.service" /etc/systemd/system/arkive-zim-manager.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-zim-manager.timer" /etc/systemd/system/arkive-zim-manager.timer
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-kiwix.service" /etc/systemd/system/arkive-kiwix.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-ap-interface.service" /etc/systemd/system/arkive-ap-interface.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-hostapd.service" /etc/systemd/system/arkive-hostapd.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-dnsmasq.service" /etc/systemd/system/arkive-dnsmasq.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-ap-channel.service" /etc/systemd/system/arkive-ap-channel.service
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-ap-channel.timer" /etc/systemd/system/arkive-ap-channel.timer
install -o root -g root -m 0644 "$REPO_ROOT/systemd/arkive-ap.target" /etc/systemd/system/arkive-ap.target

systemctl disable --now hostapd.service dnsmasq.service 2>/dev/null || true
systemctl daemon-reload

log 'Validating configuration before starting services.'
bash -n /srv/arkive/infrastructure/indexer.sh
bash -n /srv/arkive/infrastructure/zim-manager.sh
bash -n /usr/local/lib/arkive/ap-interface.sh
bash -n /usr/local/lib/arkive/sync-ap-channel.sh
bash -n /usr/lib/cgi-bin/arkive-search.sh
lighttpd -tt -f /etc/lighttpd/lighttpd.conf

log 'Enabling Arkive services.'
systemctl enable --now lighttpd.service vsftpd.service
systemctl restart lighttpd.service vsftpd.service
systemctl enable --now arkive-indexer.timer arkive-zim-manager.timer arkive-ap-channel.timer
AP_WAS_ACTIVE=0
systemctl is-active --quiet arkive-ap.target && AP_WAS_ACTIVE=1 || true
systemctl enable arkive-ap.target

# Health check: verify that the AP interface is up with the expected IP and
# that both hostapd and dnsmasq are running.  Allow enough time for the AP
# interface script's internal wlan0 wait (up to 120 s) plus at least one
# systemd restart cycle (RestartSec=30).
readonly AP_HEALTH_TIMEOUT=180

ap_is_healthy() {
    systemctl is-active --quiet arkive-ap-interface.service || return 1
    ip -4 addr show dev uap0 2>/dev/null | grep -q 'inet ' || return 1
    systemctl is-active --quiet arkive-hostapd.service || return 1
    systemctl is-active --quiet arkive-dnsmasq.service || return 1
}

wait_for_ap() {
    local elapsed=0
    while (( elapsed < AP_HEALTH_TIMEOUT )); do
        if ap_is_healthy; then
            log "Access point is healthy (took ${elapsed}s)."
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    return 1
}

report_ap_failure() {
    log 'WARNING: The access point did not become healthy within the timeout.'
    log 'Lighttpd, FTP, document indexing and Kiwix are operational independently.'
    log 'AP diagnostic logs follow; the AP is enabled and systemd will keep retrying.'
    printf '\n'
    journalctl -u arkive-ap-interface.service -u arkive-hostapd.service \
        -u arkive-dnsmasq.service -n 100 --no-pager 2>/dev/null || true
    printf '\n'
    log 'To retry manually: systemctl restart arkive-ap.target'
}

# Do not bounce wlan0 or interrupt an already-running AP during a remote update.
AP_STATUS='unknown'
if (( AP_WAS_ACTIVE )); then
    AP_STATUS='healthy'
    log 'The Arkive AP is already running; leaving it untouched to avoid disconnecting clients. Newly supplied AP settings take effect after reboot.'
elif iw dev wlan0 link 2>/dev/null | grep -q '^Connected to '; then
    CURRENT_WIFI_SSID=$(iw dev wlan0 link | awk -F': ' '/SSID:/ {print $2; exit}')
    if [[ "$CURRENT_WIFI_SSID" != "$WIFI_SSID" ]]; then
        log "The active wlan0 SSID is '$CURRENT_WIFI_SSID'. The new home Wi-Fi settings are saved and will take effect after reconnect/reboot."
    fi
    AP_STATUS='starting'
    systemctl start arkive-ap.target
    if wait_for_ap; then
        AP_STATUS='healthy'
    else
        AP_STATUS='failed'
        report_ap_failure
    fi
else
    AP_STATUS='deferred'
    log 'wlan0 is not currently associated. The AP is enabled and will start once the configured home Wi-Fi connects (reboot if necessary).'
fi

# First reconciliation pass; both managers are safe with empty content directories.
systemctl start arkive-indexer.service
systemctl start arkive-zim-manager.service

# Store a non-secret installation report.
HOME_IP=$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{split($4, address, "/"); print address[1]; exit}')
WEB_IP=${HOME_IP:-${AP_ADDRESS%/24}}
REPORT='/root/arkive-install-report.txt'
cat > "$REPORT" <<EOF_REPORT
Arkive installation completed: $(date -Is)
Hostname: $HOSTNAME_VALUE
Home Wi-Fi SSID: $WIFI_SSID
Access point SSID: $AP_SSID
Access point subnet: $AP_SUBNET
Access point channel: follows wlan0 automatically
Access point status: $AP_STATUS
FTP username: $FTP_USER
FTP directories: documents/manuals, documents/books, documents/reference, zim
Website: http://$WEB_IP/
Documents: http://$WEB_IP/documents/
Access point gateway: ${AP_ADDRESS%/24}
Kiwix: http://$WEB_IP:8080/ (starts when a stable ZIM file is uploaded)
Gemini enrichment: $([[ -n "$GEMINI_API_KEY" ]] && echo enabled || echo disabled)
Configuration backup: $BACKUP_DIR
EOF_REPORT
chmod 0600 "$REPORT"

trap - EXIT
unset WIFI_PASSWORD AP_PASSWORD FTP_PASSWORD GEMINI_API_KEY WIFI_PSK
log 'Installation completed.'
printf '\n'
printf 'Arkive portal:       http://%s/\n' "$WEB_IP"
printf 'Documents:           http://%s/documents/\n' "$WEB_IP"
printf 'Access point:        %s\n' "$AP_SSID"
printf 'Access point address: %s\n' "${AP_ADDRESS%/24}"
if [[ "$AP_STATUS" == 'failed' ]]; then
    printf 'Access point status: NOT HEALTHY — systemd will keep retrying; run: systemctl restart arkive-ap.target\n'
elif [[ "$AP_STATUS" == 'deferred' ]]; then
    printf 'Access point status: deferred until the home Wi-Fi connects (reboot if necessary)\n'
fi
printf 'FTP username:        %s\n' "$FTP_USER"
printf 'FTP upload folders:  documents/{manuals,books,reference}, zim\n'
printf 'FTP password:        the password entered during installation\n'
printf '\nThe AP channel follows the home Wi-Fi channel automatically.\n'
printf 'Content is detected after it remains unchanged for at least 2 minutes.\n'
printf 'Install report: %s\n' "$REPORT"
printf 'Configuration backup: %s\n' "$BACKUP_DIR"
