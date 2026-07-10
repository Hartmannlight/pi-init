#!/usr/bin/env bash
# Configure a stable raw-ZPL endpoint for USB-to-parallel printer adapters.
set -Eeuo pipefail

GROUP_NAME="${ZPL_GROUP:-zplraw}"
LINK_ROOT="${ZPL_LINK_ROOT:-zpl}"
RULES_DIR=/etc/udev/rules.d
MODULE_FILE=/etc/modules-load.d/zpl-usblp.conf
TMPFILES_FILE=/etc/tmpfiles.d/zpl-lock.conf
SENDER=/usr/local/bin/zpl-send
STAMP="$(date +%Y%m%d-%H%M%S)"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
info() { printf '[*] %s\n' "$*"; }
ask() { local answer; read -r -p "$1" answer; printf '%s' "$answer"; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != . && "$1" != .. ]]; }
backup() {
  if [[ -e "$1" ]]; then
    cp -a -- "$1" "$1.zpl-backup-$STAMP"
    info "Bestehende Datei gesichert: $1.zpl-backup-$STAMP"
  fi
}
attr() {
  if [[ -r "$1" ]]; then
    tr -d '\000\r\n' <"$1"
  else
    printf ''
  fi
}
udev_escape() { sed 's/[\\"]/\\&/g' <<<"$1"; }

trap 'die "Unerwarteter Fehler in Zeile $LINENO: $BASH_COMMAND"' ERR

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Mit sudo ausführen: sudo $0"
[[ -t 0 ]] || die "Dieses Setup braucht eine interaktive Eingabe. Direkt im SSH-Terminal ausführen."
for command in readlink modprobe udevadm getent flock sed install systemd-tmpfiles; do
  command -v "$command" >/dev/null || die "Benötigtes Kommando fehlt: $command"
done

usb_parent() {
  local path
  path="$(readlink -f "$1")"
  while [[ "$path" != / ]]; do
    if [[ -r "$path/idVendor" && -r "$path/idProduct" ]]; then
      printf '%s' "$path"
      return 0
    fi
    path="${path%/*}"
  done
  return 1
}

declare -a DEVICE USB_PATH VID PID SERIAL MANUFACTURER PRODUCT
discover_adapters() {
  local class_path lp device interface parent index
  DEVICE=() USB_PATH=() VID=() PID=() SERIAL=() MANUFACTURER=() PRODUCT=()
  shopt -s nullglob
  for class_path in /sys/class/usbmisc/lp*; do
    lp="$(basename "$class_path")"
    device="/dev/usb/$lp"
    [[ -c "$device" ]] || continue
    interface="$(readlink -f "$class_path/device")"
    parent="$(usb_parent "$interface" || true)"
    [[ -n "$parent" ]] || continue
    index="${#DEVICE[@]}"
    DEVICE[index]="$device"
    USB_PATH[index]="$(basename "$parent")"
    VID[index]="$(attr "$parent/idVendor")"
    PID[index]="$(attr "$parent/idProduct")"
    SERIAL[index]="$(attr "$parent/serial")"
    MANUFACTURER[index]="$(attr "$parent/manufacturer")"
    PRODUCT[index]="$(attr "$parent/product")"
  done
  shopt -u nullglob
}

info "Richte einen stabilen Raw-ZPL-Endpunkt für einen USB-zu-Parallel-Adapter ein."
info "Der Drucker wird anschließend über /dev/$LINK_ROOT/<name> angesprochen."
info "Lade das Linux-Drucker-Modul usblp und suche angeschlossene Adapter."

install -d -m 0755 /etc/modules-load.d "$RULES_DIR" /etc/tmpfiles.d /usr/local/bin
if [[ ! -f "$MODULE_FILE" ]] || ! grep -Fxq usblp "$MODULE_FILE"; then
  backup "$MODULE_FILE"
  printf '# Managed by setup-zpl-usb-parallel.sh\nusblp\n' >"$MODULE_FILE"
  info "Autostart für Kernel-Modul usblp eingerichtet."
fi
if ! modprobe usblp; then
  warn "usblp konnte nicht geladen werden. Prüfe Kernel, Blacklists und: dmesg | tail -n 50"
fi
udevadm settle || true
discover_adapters

((${#DEVICE[@]})) || die "Kein unterstützter Adapter gefunden. Erwartet wird ein /dev/usb/lp*-Gerät vom Linux-Treiber usblp. Prüfe Kabel, Hub-Stromversorgung und: dmesg | grep -Ei 'usb|usblp|lp[0-9]'"

printf '\nGefundene USB-Parallel-Adapter:\n'
for index in "${!DEVICE[@]}"; do
  printf '  %d) %-14s  USB-ID %s:%s  %s %s\n' \
    "$((index + 1))" "${DEVICE[index]}" "${VID[index]}" "${PID[index]}" \
    "${MANUFACTURER[index]:-Unbekannter Hersteller}" "${PRODUCT[index]:-Unbekanntes Modell}"
  printf '     Seriennummer: %s | aktueller USB-Pfad: %s\n' \
    "${SERIAL[index]:-(keine)}" "${USB_PATH[index]}"
done

printf '\n'
while true; do
  selection="$(ask 'Adapter-Nummer: ')"
  if [[ "$selection" =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#DEVICE[@]})); then
    selected=$((selection - 1))
    break
  fi
  printf 'Bitte eine der angezeigten Nummern eingeben.\n'
done
while true; do
  name="$(ask 'Fester Name (z.B. zebra-kueche): ')"
  valid_name "$name" && break
  printf 'Erlaubt sind Buchstaben, Ziffern, Punkt, Unterstrich und Minus.\n'
done

same_vid_pid=0
same_serial=0
for index in "${!DEVICE[@]}"; do
  if [[ "${VID[index]}:${PID[index]}" == "${VID[selected]}:${PID[selected]}" ]]; then
    ((++same_vid_pid))
  fi
  if [[ -n "${SERIAL[selected]}" && "${VID[index]}:${PID[index]}:${SERIAL[index]}" == "${VID[selected]}:${PID[selected]}:${SERIAL[selected]}" ]]; then
    ((++same_serial))
  fi
done

if [[ -n "${SERIAL[selected]}" && "$same_serial" -eq 1 ]]; then
  match_mode=serial
  info "Verwende die eindeutige Seriennummer: Der Adapter bleibt auch nach einem Portwechsel erkennbar."
elif [[ "$same_vid_pid" -eq 1 ]]; then
  match_mode=vidpid
  warn "Der Adapter hat keine eindeutige Seriennummer. Die Zuordnung ist portunabhängig, solange kein zweiter Adapter mit USB-ID ${VID[selected]}:${PID[selected]} angeschlossen wird."
  [[ "$(ask 'Diese Zuordnung verwenden? [Y/n] ')" =~ ^([nN]|nein|NEIN)$ ]] && die "Abgebrochen."
else
  printf '\n'
  warn "Mehrere angeschlossene Adapter sind baugleich und haben keine eindeutige Seriennummer."
  warn "Eine portunabhängige, zuverlässige Unterscheidung ist damit technisch nicht möglich."
  warn "Bitte einen Adapter abziehen und erneut starten oder einen Adapter mit eindeutiger Seriennummer verwenden."
  die "Keine unsichere Portbindung eingerichtet."
fi

if ! getent group "$GROUP_NAME" >/dev/null; then
  groupadd --system "$GROUP_NAME"
  info "Gruppe $GROUP_NAME angelegt."
fi
default_user="${SUDO_USER:-}"
[[ "$default_user" == root ]] && default_user=""
user="$(ask "Benutzer für ZPL-Zugriff [${default_user:-leer = nur root}]: ")"
user="${user:-$default_user}"
[[ "$user" == root ]] && user=""
if [[ -n "$user" ]]; then
  getent passwd "$user" >/dev/null || die "Benutzer existiert nicht: $user"
  usermod -aG "$GROUP_NAME" "$user"
  info "Benutzer $user zur Gruppe $GROUP_NAME hinzugefügt."
fi

rule="SUBSYSTEM==\"usbmisc\", KERNEL==\"lp[0-9]*\", ATTRS{idVendor}==\"${VID[selected]}\", ATTRS{idProduct}==\"${PID[selected]}\""
if [[ "$match_mode" == serial ]]; then
  rule+=", ATTRS{serial}==\"$(udev_escape "${SERIAL[selected]}")\""
fi
rule+=", SYMLINK+=\"$LINK_ROOT/$name\", GROUP=\"$GROUP_NAME\", MODE=\"0660\""

rule_file="$RULES_DIR/70-zpl-usb-parallel-$name.rules"
backup "$rule_file"
printf '# Managed by setup-zpl-usb-parallel.sh\n# Match mode: %s\n%s\n' "$match_mode" "$rule" >"$rule_file"
info "Udev-Regel geschrieben: $rule_file"

backup "$TMPFILES_FILE"
printf '# Managed by setup-zpl-usb-parallel.sh\nd /run/lock/zpl 0770 root %s -\n' "$GROUP_NAME" >"$TMPFILES_FILE"
systemd-tmpfiles --create "$TMPFILES_FILE"

cat >"$SENDER" <<EOF
#!/usr/bin/env bash
# Managed by setup-zpl-usb-parallel.sh
set -Eeuo pipefail

[[ \$# -ge 1 && \$# -le 2 ]] || { echo "Nutzung: zpl-send NAME [DATEI|-]" >&2; exit 2; }
name="\$1"
shift
[[ "\$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Ungültiger Druckername." >&2; exit 2; }
device="/dev/$LINK_ROOT/\$name"
lock="/run/lock/zpl/\$name.lock"

for ((attempt = 0; attempt < 30 && ! -e "\$device"; attempt++)); do sleep 0.1; done
[[ -w "\$device" ]] || { echo "Nicht verfügbar oder keine Berechtigung: \$device" >&2; exit 1; }
umask 007
: >"\$lock"
(
  flock -x 9
  if [[ \$# -eq 1 && "\$1" != - ]]; then cat -- "\$1" >"\$device"; else cat >"\$device"; fi
) 9>>"\$lock"
EOF
chmod 0755 "$SENDER"

info "Aktiviere die Regel und prüfe den neuen Gerätenamen."
udevadm control --reload-rules
udevadm trigger --subsystem-match=usbmisc
udevadm settle

printf '\nFertig eingerichtet:\n'
printf '  Gerätepfad: /dev/%s/%s\n' "$LINK_ROOT" "$name"
printf '  Erkennung:  %s\n' "$match_mode"
printf '  ZPL senden: zpl-send %s label.zpl\n' "$name"
printf '  Direkt:     cat label.zpl > /dev/%s/%s\n' "$LINK_ROOT" "$name"
[[ -n "$user" ]] && printf '\nWichtig: %s muss sich einmal neu anmelden (oder newgrp %s ausführen), damit die neue Gruppenberechtigung gilt.\n' "$user" "$GROUP_NAME"
if [[ ! -e "/dev/$LINK_ROOT/$name" ]]; then
  warn "Der Name ist noch nicht sichtbar. Adapter einmal ab- und wieder anstecken und dann prüfen: ls -l /dev/$LINK_ROOT/$name"
fi
