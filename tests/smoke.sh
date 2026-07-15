#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/bootstrap.sh"
bash -n "$ROOT/init.sh"
bash -n "$ROOT/scripts/pi-health"
bash -n "$ROOT/scripts/setup-zpl-usb-parallel.sh"
bash -n "$ROOT/tests/metrics.sh"
metrics_script="$(mktemp)"
trap 'rm -f -- "$metrics_script"' EXIT
awk '
  /^  cat >"\$metrics_tmp" <<'\''METRICS'\''$/ { capture=1; next }
  capture && /^METRICS$/ { exit }
  capture { print }
' "$ROOT/init.sh" >"$metrics_script"
test -s "$metrics_script"
bash -n "$metrics_script"
grep -Fq 'PI_INIT_PUBLIC_KEY_DEFAULT=' "$ROOT/init.sh"
grep -Fq 'mv -f -- "$TMP_FILE" "$OUTPUT_FILE"' "$ROOT/init.sh"
grep -Fq 'PI_INIT_MONITORING_ONLY' "$ROOT/bootstrap.sh"
grep -Fq 'pi_zpl_agent_scrape_success' "$ROOT/init.sh"
grep -Fq 'zpl-agent.prom' "$ROOT/init.sh"
grep -Fq -- '--monitoring-only' "$ROOT/init.sh"
grep -Fq 'file_sd_configs' "$ROOT/init.sh"
bash "$ROOT/tests/metrics.sh"
printf 'Smoke tests erfolgreich.\n'
