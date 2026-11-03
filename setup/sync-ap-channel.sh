#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG='/etc/hostapd/arkive.conf'
frequency=$(iw dev wlan0 link | awk '/freq:/ {print int($2); exit}')
[[ "$frequency" =~ ^[0-9]+$ ]] || exit 0

if (( frequency == 2484 )); then
    channel=14
elif (( frequency >= 2412 && frequency <= 2472 )); then
    channel=$(((frequency - 2407) / 5))
else
    echo "Home Wi-Fi frequency $frequency MHz is not supported by the 2.4 GHz AP." >&2
    exit 1
fi

current=$(awk -F= '$1 == "channel" {print $2; exit}' "$CONFIG")
[[ "$current" == "$channel" ]] && exit 0

temporary=$(mktemp)
awk -v channel="$channel" '
    /^channel=/ { print "channel=" channel; found=1; next }
    { print }
    END { if (!found) print "channel=" channel }
' "$CONFIG" > "$temporary"
cat "$temporary" > "$CONFIG"
rm -f "$temporary"

if systemctl is-active --quiet arkive-hostapd.service; then
    systemctl restart arkive-hostapd.service
fi
echo "Arkive AP channel synchronized to home Wi-Fi channel $channel."
