#!/usr/bin/env bash
set -Eeuo pipefail

readonly WLAN_INTERFACE='wlan0'
readonly AP_INTERFACE='uap0'
readonly HOSTAPD_CONFIG='/etc/hostapd/arkive.conf'
source /etc/arkive/network.env

get_channel() {
    local frequency
    frequency=$(iw dev "$WLAN_INTERFACE" link | awk '/freq:/ {print int($2); exit}')
    [[ "$frequency" =~ ^[0-9]+$ ]] || return 1
    if (( frequency == 2484 )); then
        printf '14\n'
    elif (( frequency >= 2412 && frequency <= 2472 )); then
        printf '%s\n' "$(((frequency - 2407) / 5))"
    else
        echo "Unsupported home Wi-Fi frequency: $frequency MHz (Arkive AP requires 2.4 GHz)." >&2
        return 1
    fi
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

check_subnet_overlap() {
    local route network prefix mask route_int ap_int
    local ap_network=${AP_SUBNET%%/*}
    ap_int=$(ipv4_to_int "$ap_network")
    while IFS= read -r route; do
        [[ "$route" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]] || continue
        network=${BASH_REMATCH[1]}
        prefix=${BASH_REMATCH[2]}
        (( prefix <= 32 )) || continue
        if (( prefix == 0 )); then mask=0; else mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff )); fi
        route_int=$(ipv4_to_int "$network")
        if (( (route_int & mask) == (ap_int & mask) )); then
            echo "Arkive AP subnet $AP_SUBNET overlaps home Wi-Fi network $route. Choose a different AP subnet." >&2
            return 1
        fi
    done < <(ip -4 route show dev "$WLAN_INTERFACE" scope link | awk '{print $1}')
}

set_hostapd_channel() {
    local channel=$1 temporary
    temporary=$(mktemp)
    awk -v channel="$channel" '
        /^channel=/ { print "channel=" channel; found=1; next }
        { print }
        END { if (!found) print "channel=" channel }
    ' "$HOSTAPD_CONFIG" > "$temporary"
    cat "$temporary" > "$HOSTAPD_CONFIG"
    rm -f "$temporary"
}

start_ap() {
    local attempt channel route_ready=0
    for attempt in $(seq 1 60); do
        if channel=$(get_channel 2>/dev/null) && \
            [[ -n "$(ip -4 route show dev "$WLAN_INTERFACE" scope link)" ]]; then
            route_ready=1
            break
        fi
        sleep 2
    done
    (( route_ready )) || {
        echo 'wlan0 is not connected to the home Wi-Fi or has no IPv4 route. Check the Wi-Fi settings and try again.' >&2
        exit 1
    }

    check_subnet_overlap
    set_hostapd_channel "$channel"

    if ! iw dev "$AP_INTERFACE" info >/dev/null 2>&1; then
        iw dev "$WLAN_INTERFACE" interface add "$AP_INTERFACE" type __ap
    fi
    ip link set "$AP_INTERFACE" down 2>/dev/null || true
    ip address flush dev "$AP_INTERFACE" 2>/dev/null || true
    ip address add "$AP_ADDRESS" dev "$AP_INTERFACE"
    ip link set "$AP_INTERFACE" up
    echo "Arkive AP interface ready on channel $channel."
}

stop_ap() {
    if iw dev "$AP_INTERFACE" info >/dev/null 2>&1; then
        ip link set "$AP_INTERFACE" down 2>/dev/null || true
        iw dev "$AP_INTERFACE" del
    fi
}

case "${1:-}" in
    start) start_ap ;;
    stop) stop_ap ;;
    *) echo "Usage: $0 {start|stop}" >&2; exit 2 ;;
esac
