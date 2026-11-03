# Arkive

**Knowledge. Preserved.**

Arkive turns a fresh DietPi installation on the original Raspberry Pi Zero W into an isolated offline knowledge appliance. The installer configures the home Wi-Fi connection, a same-channel local access point, a web portal, document search, Kiwix, and FTP-only content upload.

The repository contains software and configuration only. **It does not contain or download documents, maps, or ZIM content.** Users upload their own content through FTP.

## Target platform

- Original Raspberry Pi Zero W (ARMv6, 512 MB RAM)
- 32-bit Debian `armhf`, Debian 13 Trixie, and an `armv6l` kernel
- A 2.4 GHz home Wi-Fi network
- A fresh DietPi installation with SSH or local console access

The installer intentionally rejects non-`armhf` systems. The package `kiwix-tools` must be available from the configured Debian/DietPi repositories for the target release.

## Install

Arkive is designed for a fresh installation of DietPi on a Raspberry Pi Zero W.

Connect your Raspberry Pi to your home Wi-Fi network, SSH into it, and run:

```bash
curl -fsSL https://raw.githubusercontent.com/markusand/arkive/main/install.sh | sudo bash
````

The installer asks for all machine-specific settings at the beginning, validates them, displays a summary, and asks for confirmation before installing packages or changing configuration. To validate prompts and settings without applying changes, run the local installer with `--dry-run` (or append `--dry-run` to the remote command using `sudo bash -s -- --dry-run`).

### Installer prompts

| Setting | Default / behaviour |
| --- | --- |
| Hostname | `arkive` |
| Wi-Fi regulatory country | `AD` |
| Home Wi-Fi SSID | Required |
| Home Wi-Fi password | Hidden; empty means open Wi-Fi |
| Access point SSID | `arkive` |
| Access point password | Hidden; empty means an open AP |
| Access point subnet | `192.168.50.0/24` |
| FTP username | `arkiveftp` |
| FTP password | Hidden; minimum 8 characters |
| Timezone | `Europe/Andorra` |
| Gemini API key | Optional; hidden; local indexing works without it |

**The AP channel is never prompted for.** Arkive detects the channel used by `wlan0` and configures `uap0` to use the same 2.4 GHz channel. A timer checks periodically and restarts hostapd if the home router changes channel.

The installer does not bounce `wlan0` during a remote SSH session. It saves the supplied Wi-Fi configuration for the next connection/reboot. If the Pi is already connected to the supplied SSID, the access point can be started immediately. On a re-run, an already-active AP is left untouched to avoid disconnecting clients; changes to its SSID/password/subnet take effect after reboot.

## FTP content upload

Connect to the Pi's IP address using the FTP username and password entered during installation. The FTP account is jailed and can write only to these locations:

```text
FTP root/
├── documents/
│   ├── manuals/
│   ├── books/
│   └── reference/
└── zim/
```

The FTP account cannot modify the portal HTML, search CGI, database, service configuration, or private infrastructure files.

### Documents

Supported document formats:

- PDF
- TXT
- Markdown (`.md`)

Upload files directly into `documents/manuals`, `documents/books`, or `documents/reference`. Nested folders are supported.

Every two minutes, Arkive scans the folders. The managers also check whether a `vsftpd` process still has the file open. After the transfer closes, a file must remain unchanged for at least 120 seconds before processing. The indexer:

- Extracts PDF metadata and text locally using Poppler.
- Uses filename and extracted text as local searchable metadata.
- Optionally asks Gemini to enrich metadata when an API key was supplied.
- Falls back to local metadata if Gemini is absent or unavailable.
- Updates SQLite and its FTS5 index.
- Removes index entries when source files are deleted.

The local-only mode is fully functional. Without Gemini, search metadata is built from PDF metadata and a bounded text sample (first 30 PDF pages / up to 30 KB per file); this is not full-document indexing. Image-only/scanned PDFs without an embedded text layer are not OCR-processed and will not be searchable. AI enrichment is an optional enhancement, not a dependency.

### ZIM files

Upload `.zim` files into `zim/`. Arkive waits until all ZIM files are stable, rebuilds `library.xml` using `kiwix-manage`, and starts or restarts Kiwix only when the library changes. Deleting a ZIM removes it from the library automatically. If no ZIM files remain, Kiwix is stopped.

Kiwix is served on port `8080`. The portal's Offline library card checks whether Kiwix is available and shows an upload hint when no ZIM has been added yet.

## Network design

- `wlan0`: connection to the configured home Wi-Fi.
- `uap0`: local Arkive access point.
- Default AP address: `192.168.50.1/24`.
- Default DHCP pool: `192.168.50.10`–`192.168.50.100`.
- DHCP only; no DNS service, default gateway, NAT, or IP forwarding is configured for AP clients.
- AP channel follows the home Wi-Fi channel.

Clients connected to the AP can open `http://192.168.50.1/` and use FTP at `192.168.50.1`.

The AP is open if no AP password is supplied. FTP is plain FTP (not FTPS), so credentials and transfers are not encrypted on the network. Use a trusted LAN/AP; choose an AP password if the access point should not be open.

## Services and paths

| Purpose | Service / path |
| --- | --- |
| Portal and document site | Lighttpd, port `80` |
| Kiwix | `arkive-kiwix.service`, port `8080` |
| FTP | vsftpd, port `21`, passive `40000`–`40010` |
| AP | `arkive-ap.target` |
| Document indexing | `arkive-indexer.timer` |
| ZIM library reconciliation | `arkive-zim-manager.timer` |
| AP channel synchronization | `arkive-ap-channel.timer` |
| Application root | `/srv/arkive` |
| Public site | `/srv/arkive/site` |
| Database | `/srv/arkive/data/catalog.db` |
| ZIM storage | `/srv/arkive/data/zim` |
| Private scripts/config | `/srv/arkive/infrastructure` |

## Diagnostics

```bash
systemctl status lighttpd vsftpd arkive-ap.target
systemctl status arkive-indexer.timer arkive-zim-manager.timer arkive-ap-channel.timer
journalctl -u arkive-indexer.service -n 100 --no-pager
journalctl -u arkive-zim-manager.service -n 100 --no-pager
journalctl -u arkive-hostapd.service -n 100 --no-pager
journalctl -u arkive-dnsmasq.service -n 100 --no-pager
```

Installer log: `/var/log/arkive-install.log`

Non-secret installation report: `/root/arkive-install-report.txt`

Configuration backup: `/root/arkive-backups/<timestamp>/configuration.tar`

## Re-running / updating

The installer is designed to be re-runnable: it redeploys Arkive-owned application/configuration files, preserves uploaded content and the SQLite database, and backs up existing system configuration before applying changes. It prompts again and reapplies the supplied settings. The FTP username is fixed after the first successful installation; the password can be changed on a re-run. Review the prompt summary carefully before confirming.

The installer does not automatically remove Debian packages or user/group accounts if a later step fails. It restores backed-up configuration files and leaves the backup archive for recovery.

## Development checks

Run the local checks before publishing:

```bash
bash tests/check.sh
```

The tests validate shell syntax, Unicode tokenization, the FTS5 schema, accent-insensitive matching, and trigger behaviour on the development machine. They do not replace a full hardware test on an original Raspberry Pi Zero W.

## License

MIT. See [LICENSE](LICENSE).
