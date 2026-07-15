#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/output"

awk '
  /^  cat >"\$metrics_tmp" <<'\''METRICS'\''$/ { capture=1; next }
  capture && /^METRICS$/ { exit }
  capture { print }
' "$ROOT/init.sh" >"$WORK/pi-prometheus-metrics"

sed -i \
  -e "s#^OUTPUT_DIR=.*#OUTPUT_DIR=\"$WORK/output\"#" \
  -e "s#^ZPL_ENDPOINT=.*#ZPL_ENDPOINT=\"$WORK/zpl.metrics\"#" \
  -e "s#/usr/local/bin/zpl-agent#$WORK/zpl-agent#g" \
  -e 's#zpl-agent.service#test-zpl-agent.service#g' \
  "$WORK/pi-prometheus-metrics"

cat >"$WORK/bin/systemctl" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
cat >"$WORK/bin/timedatectl" <<'EOF'
#!/usr/bin/env sh
printf 'no\n'
EOF
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env sh
for argument do source="$argument"; done
cat "$source"
EOF
chmod +x "$WORK/bin/systemctl" "$WORK/bin/timedatectl" "$WORK/bin/curl"

PATH="$WORK/bin:$PATH" bash "$WORK/pi-prometheus-metrics"
grep -Fxq 'pi_zpl_agent_configured 0' "$WORK/output/pi.prom"
grep -Fxq 'pi_zpl_agent_scrape_success 0' "$WORK/output/pi.prom"
test ! -e "$WORK/output/zpl-agent.prom"

printf '# TYPE zpl_agent_build_info gauge\nzpl_agent_build_info{version="test",commit="test"} 1\nzpl_printer_present{printer="test"} 1\n' >"$WORK/zpl.metrics"
install -m 0755 /dev/null "$WORK/zpl-agent"
PATH="$WORK/bin:$PATH" bash "$WORK/pi-prometheus-metrics"
grep -Fxq 'pi_zpl_agent_configured 1' "$WORK/output/pi.prom"
grep -Fxq 'pi_zpl_agent_scrape_success 1' "$WORK/output/pi.prom"
grep -Fq 'zpl_printer_present{printer="test"} 1' "$WORK/output/zpl-agent.prom"

printf 'Metriktests erfolgreich.\n'
