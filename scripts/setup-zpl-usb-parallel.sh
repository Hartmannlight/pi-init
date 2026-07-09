#!/usr/bin/env bash
# Stable /dev/zpl/<name> aliases for USB-to-parallel ZPL adapters (usblp).
set -Eeuo pipefail

GROUP_NAME="${ZPL_GROUP:-zplraw}"
LINK_ROOT="${ZPL_LINK_ROOT:-zpl}"
RULES_DIR=/etc/udev/rules.d
MODULE_FILE=/etc/modules-load.d/zpl-usblp.conf
SENDER=/usr/local/bin/zpl-send
STAMP="$(date +%Y%m%d-%H%M%S)"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
info() { printf '[*] %s\n' "$*"; }
ask() { local a; read -r -p "$1" a; printf '%s' "$a"; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != . && "$1" != .. ]]; }
backup() { [[ -e "$1" ]] && cp -a -- "$1" "$1.zpl-backup-$STAMP"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Mit sudo ausführen: sudo $0"
for cmd in readlink modprobe udevadm getent flock; do command -v "$cmd" >/dev/null || die "Benötigtes Kommando fehlt: $cmd"; done

mkdir -p /etc/modules-load.d
if [[ ! -f "$MODULE_FILE" ]] || ! grep -Fxq usblp "$MODULE_FILE"; then
  backup "$MODULE_FILE"
  printf '# Managed by setup-zpl-usb-parallel.sh\nusblp\n' >"$MODULE_FILE"
fi
if ! modprobe usblp; then warn "usblp konnte nicht geladen werden; prüfe Blacklists oder Kernel-Unterstützung."; fi
udevadm settle || true

declare -a DEV USB VID PID SERIAL MFR PRODUCT
usb_parent() { local p; p="$(readlink -f "$1")"; while [[ "$p" != / ]]; do [[ -r "$p/idVendor" && -r "$p/idProduct" ]] && { printf '%s' "$p"; return; }; p="${p%/*}"; done; return 1; }
attr() { [[ -r "$1" ]] && tr -d '\000\r\n' <"$1"; }
shopt -s nullglob
for cls in /sys/class/usbmisc/lp*; do
  lp="$(basename "$cls")"; dev="/dev/usb/$lp"; [[ -e "$dev" ]] || continue
  iface="$(readlink -f "$cls/device")"; parent="$(usb_parent "$iface" || true)"; [[ -n "$parent" ]] || continue
  i="${#DEV[@]}"; DEV[i]="$dev"; USB[i]="$parent"; VID[i]="$(attr "$parent/idVendor")"; PID[i]="$(attr "$parent/idProduct")"; SERIAL[i]="$(attr "$parent/serial")"; MFR[i]="$(attr "$parent/manufacturer")"; PRODUCT[i]="$(attr "$parent/product")"
done
shopt -u nullglob
((${#DEV[@]})) || die "Keine /dev/usb/lp*-Geräte gefunden. Prüfe: dmesg | grep -i usblp"

printf '\nGefundene Adapter:\n'
for i in "${!DEV[@]}"; do printf '  %d) %s  %s:%s  %s %s  Seriennr.: %s\n' "$((i+1))" "${DEV[i]}" "${VID[i]}" "${PID[i]}" "${MFR[i]:-unbekannt}" "${PRODUCT[i]:-unbekannt}" "${SERIAL[i]:-(keine)}"; done
while true; do choice="$(ask 'Adapter-Nummer: ')"; [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#DEV[@]})) && { i=$((choice-1)); break; }; done
while true; do name="$(ask 'Stabiler Name (z.B. zebra1): ')"; valid_name "$name" && break; printf 'Erlaubt: Buchstaben, Ziffern, Punkt, Unterstrich, Minus.\n'; done

same_vidpid=0; same_serial=0
for n in "${!DEV[@]}"; do [[ "${VID[n]}:${PID[n]}" == "${VID[i]}:${PID[i]}" ]] && ((++same_vidpid)); [[ -n "${SERIAL[i]}" && "${VID[n]}:${PID[n]}:${SERIAL[n]}" == "${VID[i]}:${PID[i]}:${SERIAL[i]}" ]] && ((++same_serial)); done
if [[ -n "${SERIAL[i]}" && "$same_serial" -eq 1 ]]; then mode=serial
elif [[ "$same_vidpid" -eq 1 ]]; then
  [[ "$(ask 'Keine eindeutige Seriennummer; VID:PID-Match verwenden? [Y/n] ')" =~ ^([nN]|nein|NEIN)$ ]] && die "Abgebrochen."
  mode=vidpid
else
  warn "Mehrere identische Adapter ohne eindeutige Seriennummer: Portbindung ist nicht portwechsel-sicher."
  [[ "$(ask 'Trotzdem an aktuellen USB-Port binden? [y/N] ')" =~ ^([yYjJ]|ja|JA|yes|YES)$ ]] || die "Abgebrochen."
  mode=port
fi

if ! getent group "$GROUP_NAME" >/dev/null; then groupadd --system "$GROUP_NAME"; fi
user="${SUDO_USER:-}"; [[ "$user" == root ]] && user=""
user="$(ask "Benutzer für Raw-ZPL-Zugriff [${user:-leer=nur root}]: ")"; user="${user:-${SUDO_USER:-}}"; [[ "$user" == root ]] && user=""
if [[ -n "$user" ]]; then getent passwd "$user" >/dev/null || die "Benutzer existiert nicht: $user"; usermod -aG "$GROUP_NAME" "$user"; fi

rule="SUBSYSTEM==\"usbmisc\", KERNEL==\"lp[0-9]*\", ATTRS{idVendor}==\"${VID[i]}\", ATTRS{idProduct}==\"${PID[i]}\""
case "$mode" in serial) rule+=", ATTRS{serial}==\"${SERIAL[i]}\"";; port) rule+=", KERNELS==\"$(basename "${USB[i]}")\"";; esac
rule+=", SYMLINK+=\"$LINK_ROOT/$name\", GROUP=\"$GROUP_NAME\", MODE=\"0660\""
rule_file="$RULES_DIR/70-zpl-usb-parallel-$name.rules"
backup "$rule_file"
printf '# Managed by setup-zpl-usb-parallel.sh\n# Match mode: %s\n%s\n' "$mode" "$rule" >"$rule_file"

cat >"$SENDER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 1 ]] || { echo "Nutzung: zpl-send NAME [DATEI|-]" >&2; exit 2; }
name="$1"; shift
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
dev="/dev/zpl/$name"; lock="/run/lock/zpl-$name.lock"
for ((i=0;i<100 && ! -e "$dev";i++)); do sleep .1; done
[[ -w "$dev" ]] || { echo "Nicht schreibbar oder nicht vorhanden: $dev" >&2; exit 1; }
mkdir -p /run/lock
old_umask="$(umask)"
umask 000
: >>"$lock"
umask "$old_umask"
chmod 0666 "$lock" 2>/dev/null || true
(
  flock -x 9
  if (($#)); then cat "$@" >"$dev"; else cat >"$dev"; fi
) 9>>"$lock"
EOF
chmod 0755 "$SENDER"
udevadm control --reload-rules
udevadm trigger --subsystem-match=usbmisc || true
udevadm settle || true
printf '\nFertig: /dev/%s/%s\n' "$LINK_ROOT" "$name"
[[ -n "$user" ]] && printf 'Bitte einmal neu einloggen (oder: newgrp %s), damit %s die Gruppe erhält.\n' "$GROUP_NAME" "$user"
printf 'Senden: zpl-send %s label.zpl\n' "$name"
