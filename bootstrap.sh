#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${PI_INIT_REPOSITORY:-Hartmannlight/pi-init}"
REF="${PI_INIT_REF:-main}"
TARGET_USER="${USER:-$(id -un)}"
TARGET_HOME="${HOME:?HOME ist nicht gesetzt}"
SCRIPTS_DIR="${TARGET_HOME}/scripts"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP_DIR=""

cleanup() {
  [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
}

fail() {
  printf 'FEHLER: %s\n' "$*" >&2
  exit 1
}

trap cleanup EXIT
trap 'fail "Bootstrap in Zeile $LINENO fehlgeschlagen (Befehl: $BASH_COMMAND)."' ERR

[[ "$(id -u)" -ne 0 ]] || fail "Bitte den Bootstrap als normaler Benutzer, nicht mit sudo, starten."
command -v tar >/dev/null 2>&1 || fail "tar wird zum Entpacken benötigt."

TMP_DIR="$(mktemp -d -t pi-init.XXXXXXXX)"
ARCHIVE="${TMP_DIR}/pi-init.tar.gz"
URL="https://github.com/${REPOSITORY}/archive/refs/heads/${REF}.tar.gz"

printf 'Lade %s (%s) ...\n' "$REPOSITORY" "$REF"
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --connect-timeout 15 "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$ARCHIVE" "$URL"
else
  fail "Weder curl noch wget ist installiert. Bitte zuerst eines davon installieren."
fi

tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/init.sh" ]] || fail "Das Archiv enthält kein init.sh."

mkdir -p "$SCRIPTS_DIR"

copy_one() {
  local source="$1" destination="$2"
  mkdir -p "$(dirname "$destination")"
  if [[ -f "$destination" ]] && ! cmp -s "$source" "$destination"; then
    cp -a -- "$destination" "${destination}.pi-init-backup-${STAMP}"
    printf 'Sicherung: %s\n' "${destination}.pi-init-backup-${STAMP}"
  fi
  if [[ ! -f "$destination" ]] || ! cmp -s "$source" "$destination"; then
    cp -a -- "$source" "$destination"
  fi
}

copy_one "$SOURCE_DIR/init.sh" "$SCRIPTS_DIR/pi-init.sh"
chmod 0755 "$SCRIPTS_DIR/pi-init.sh"

if [[ -d "$SOURCE_DIR/scripts" ]]; then
  while IFS= read -r -d '' source; do
    relative="${source#"$SOURCE_DIR/scripts/"}"
    copy_one "$source" "$SCRIPTS_DIR/$relative"
    chmod 0755 "$SCRIPTS_DIR/$relative"
  done < <(find "$SOURCE_DIR/scripts" -type f -print0)
fi

printf 'Skripte wurden für %s nach %s kopiert.\n' "$TARGET_USER" "$SCRIPTS_DIR"
printf 'Starte nun die interaktive Einrichtung mit sudo ...\n'
[[ -r /dev/tty ]] || fail "Kein interaktives Terminal gefunden. Bitte sudo '$SCRIPTS_DIR/pi-init.sh' ausführen."
if [[ -n "${PI_INIT_PUBLIC_KEY:-}" ]]; then
  sudo --preserve-env=PI_INIT_PUBLIC_KEY bash "$SCRIPTS_DIR/pi-init.sh" </dev/tty
else
  sudo bash "$SCRIPTS_DIR/pi-init.sh" </dev/tty
fi
