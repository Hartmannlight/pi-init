#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/bootstrap.sh"
bash -n "$ROOT/init.sh"
bash -n "$ROOT/scripts/pi-health"
bash -n "$ROOT/scripts/setup-zpl-usb-parallel.sh"
grep -Fq 'PI_INIT_PUBLIC_KEY_DEFAULT=' "$ROOT/init.sh"
grep -Fq 'mv -f -- "$TMP_FILE" "$OUTPUT_FILE"' "$ROOT/init.sh"
printf 'Smoke tests erfolgreich.\n'
