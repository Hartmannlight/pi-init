#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export LC_ALL=C

# Diesen Wert vor dem produktiven Einsatz durch den gewünschten Public Key
# ersetzen. Nur öffentliche Schlüssel gehören in dieses Repository.
PI_INIT_PUBLIC_KEY_DEFAULT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILFaitZra5U5uUV/UaFBgMOduNJQqfbWlnRLLA0go37A network@jahnstr"
PI_INIT_PUBLIC_KEY="${PI_INIT_PUBLIC_KEY:-$PI_INIT_PUBLIC_KEY_DEFAULT}"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/pi-init"
LOG_FILE="${LOG_DIR}/pi-init-${STAMP}.log"
BACKUP_SUFFIX=".pi-init-backup-${STAMP}"
TEXTFILE_DIR="/run/node-exporter-textfile"
STATIC_NETWORK_REQUESTED=0
STATIC_IP=""
NETWORK_INTERFACE=""
TARGET_USER=""
TARGET_HOME=""
NEW_HOSTNAME=""
FAILURE_REPORTED=0
declare -a SUMMARY_OK=()
declare -a SUMMARY_WARN=()
declare -a TODO=()

plain_error() {
  printf 'FEHLER: %s\n' "$*" >&2
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  plain_error "Dieses Init-Skript darf nur mit sudo ausgeführt werden: sudo $0"
  exit 1
fi

mkdir -p "$LOG_DIR"
chmod 0750 "$LOG_DIR"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  FAILURE_REPORTED=1
  printf '\nFEHLER: %s\n' "$*" >&2
  printf 'Vollständiges Protokoll: %s\n' "$LOG_FILE" >&2
  exit 1
}

on_error() {
  local line="$1" command="$2" status="$3"
  [[ "$FAILURE_REPORTED" -eq 1 ]] && exit "$status"
  printf '\nFEHLER: Unerwarteter Fehler in Zeile %s (Status %s).\n' "$line" "$status" >&2
  printf 'Befehl: %s\nProtokoll: %s\n' "$command" "$LOG_FILE" >&2
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

section() {
  printf '\n===== %s =====\n' "$*"
}

ask() {
  local prompt="$1" default="${2-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    printf '%s' "$answer"
  fi
}

backup_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  cp -a -- "$path" "${path}${BACKUP_SUFFIX}"
  printf 'Sicherung erstellt: %s\n' "${path}${BACKUP_SUFFIX}"
}

install_if_changed() {
  local source="$1" destination="$2" mode="$3"
  if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then
    rm -f -- "$source"
    printf 'Unverändert: %s\n' "$destination"
    return 0
  fi
  [[ ! -e "$destination" ]] || backup_file "$destination"
  install -D -m "$mode" "$source" "$destination"
  rm -f -- "$source"
  printf 'Aktualisiert: %s\n' "$destination"
}

valid_hostname() {
  local pattern='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
  [[ "$1" =~ $pattern ]]
}

valid_ipv4() {
  local ip="$1" part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<<"$ip"
  for part in "${parts[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

detect_platform() {
  section "System prüfen"
  [[ -r /etc/os-release ]] || fail "/etc/os-release fehlt; das System wird nicht unterstützt."
  # shellcheck disable=SC1091
  . /etc/os-release
  local family="${ID:-} ${ID_LIKE:-}"
  if [[ ! "$family" =~ (raspbian|debian|ubuntu) ]]; then
    fail "Nicht unterstütztes System: ${PRETTY_NAME:-unbekannt}. Erwartet: Raspberry Pi OS, Debian oder Ubuntu."
  fi
  command -v systemctl >/dev/null 2>&1 || fail "systemd ist erforderlich."
  command -v apt-get >/dev/null 2>&1 || fail "apt-get ist erforderlich."
  printf 'Unterstütztes System erkannt: %s\n' "${PRETTY_NAME:-$ID}"
  SUMMARY_OK+=("Betriebssystem unterstützt: ${PRETTY_NAME:-$ID}")
}

detect_target_user() {
  TARGET_USER="${SUDO_USER:-}"
  [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || fail "Das Skript muss von einem normalen Benutzer mit sudo gestartet werden."
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || fail "Home-Verzeichnis für $TARGET_USER nicht gefunden."
  printf 'Zielbenutzer: %s (%s)\n' "$TARGET_USER" "$TARGET_HOME"
}

configure_hostname() {
  section "Hostname"
  local current requested hosts_tmp
  current="$(hostnamectl --static 2>/dev/null || hostname)"
  printf 'Aktueller Hostname: %s\n' "$current"
  while true; do
    requested="$(ask "Neuer Hostname (Enter behält den aktuellen)" "$current")"
    valid_hostname "$requested" && break
    printf 'Ungültiger Hostname. Erlaubt sind Buchstaben, Ziffern und Bindestriche.\n'
  done
  NEW_HOSTNAME="$requested"
  if [[ "$requested" == "$current" ]]; then
    SUMMARY_OK+=("Hostname beibehalten: $current")
    return
  fi
  backup_file /etc/hostname
  backup_file /etc/hosts
  hostnamectl set-hostname "$requested"
  hosts_tmp="$(mktemp)"
  awk -v old="$current" -v new="$requested" '
    $1 == "127.0.1.1" { $0 = "127.0.1.1\t" new; found=1 }
    { print }
    END { if (!found) print "127.0.1.1\t" new }
  ' /etc/hosts >"$hosts_tmp"
  install -m 0644 "$hosts_tmp" /etc/hosts
  rm -f "$hosts_tmp"
  SUMMARY_OK+=("Hostname geändert: $current -> $requested")
}

select_packages() {
  section "Paketauswahl"
  local -a packages=(git curl wget nano tree python3 unzip ca-certificates rsync zip jq htop tmux dnsutils lsof ncdu ripgrep python3-pip python3-venv)
  local -a enabled=()
  local index input token
  for index in "${!packages[@]}"; do
    if ((index < 8)); then enabled[index]=1; else enabled[index]=0; fi
  done
  printf 'Nummern eingeben, deren Auswahl umgeschaltet werden soll; Enter übernimmt die Vorgabe.\n'
  for index in "${!packages[@]}"; do
    if [[ "${enabled[index]}" -eq 1 ]]; then
      printf '  %2d [x] %s\n' "$((index + 1))" "${packages[index]}"
    else
      printf '  %2d [ ] %s\n' "$((index + 1))" "${packages[index]}"
    fi
  done
  read -r -p "Auswahl umschalten (z.B. 4 9 12): " input
  for token in $input; do
    if [[ "$token" =~ ^[0-9]+$ ]] && ((token >= 1 && token <= ${#packages[@]})); then
      index=$((token - 1))
      enabled[index]=$((1 - enabled[index]))
    else
      printf 'Ignoriere ungültige Auswahl: %s\n' "$token"
    fi
  done
  SELECTED_PACKAGES=()
  for index in "${!packages[@]}"; do
    [[ "${enabled[index]}" -eq 1 ]] && SELECTED_PACKAGES+=("${packages[index]}")
  done
  printf 'Ausgewählt: %s\n' "${SELECTED_PACKAGES[*]:-(keine)}"
}

install_packages() {
  section "Pakete aktualisieren und installieren"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  apt-get install -y unattended-upgrades prometheus-node-exporter "${SELECTED_PACKAGES[@]}"
  SUMMARY_OK+=("apt update/upgrade abgeschlossen")
  SUMMARY_OK+=("Pakete installiert: ${SELECTED_PACKAGES[*]:-(keine optionalen)}")
}

configure_unattended_upgrades() {
  section "Automatische Sicherheitsupdates"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  install_if_changed "$tmp" /etc/apt/apt.conf.d/20auto-upgrades 0644
  systemctl enable --now unattended-upgrades.service
  SUMMARY_OK+=("unattended-upgrades aktiviert")
}

install_ssh_key() {
  section "SSH-Schlüssel"
  if [[ "$PI_INIT_PUBLIC_KEY" == *REPLACE_WITH_YOUR_PUBLIC_KEY* ]]; then
    SUMMARY_WARN+=("SSH-Schlüssel nicht installiert: Repository enthält noch den Platzhalter")
    TODO+=("PI_INIT_PUBLIC_KEY_DEFAULT in init.sh durch den öffentlichen Schlüssel ersetzen und pi-init erneut ausführen")
    printf 'WARNUNG: Public-Key-Platzhalter erkannt; Installation wird übersprungen.\n'
    return
  fi
  if [[ ! "$PI_INIT_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    fail "Der konfigurierte öffentliche SSH-Schlüssel hat kein plausibles OpenSSH-Format."
  fi
  local ssh_dir="$TARGET_HOME/.ssh" auth_keys="$TARGET_HOME/.ssh/authorized_keys" key_identity
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$ssh_dir"
  touch "$auth_keys"
  chown "$TARGET_USER:$TARGET_USER" "$auth_keys"
  chmod 0600 "$auth_keys"
  key_identity="$(awk '{print $1 " " $2}' <<<"$PI_INIT_PUBLIC_KEY")"
  if awk '{print $1 " " $2}' "$auth_keys" | grep -Fx -- "$key_identity" >/dev/null; then
    printf 'SSH-Schlüssel ist bereits vorhanden.\n'
  else
    printf '%s\n' "$PI_INIT_PUBLIC_KEY" >>"$auth_keys"
    printf 'SSH-Schlüssel wurde ergänzt.\n'
  fi
  SUMMARY_OK+=("SSH-Public-Key für $TARGET_USER vorhanden; Passwort-Anmeldung blieb unverändert")
}

candidate_ip() {
  local host ip
  for ((host = 119; host >= 100; host--)); do
    ip="192.168.0.$host"
    if ! ip neigh show 2>/dev/null | awk '{print $1}' | grep -Fxq "$ip" && ! ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      printf '%s' "$ip"
      return
    fi
  done
  printf '192.168.0.119'
}

configure_networkmanager() {
  local ip="$1" prefix="$2" gateway="$3" dns="$4" connection dump uuid profile
  connection="$(nmcli -g GENERAL.CONNECTION device show "$NETWORK_INTERFACE" | head -n 1)"
  [[ -n "$connection" ]] || return 1
  uuid="$(nmcli -g connection.uuid connection show "$connection" | head -n 1)"
  if [[ -n "$uuid" && -d /etc/NetworkManager/system-connections ]]; then
    while IFS= read -r -d '' profile; do
      grep -Fq "uuid=$uuid" "$profile" && backup_file "$profile"
    done < <(find /etc/NetworkManager/system-connections -maxdepth 1 -type f -print0)
  fi
  dump="/etc/NetworkManager/pi-init-${connection//\//_}-${STAMP}.txt"
  (umask 077; nmcli connection show "$connection" >"$dump")
  nmcli connection modify "$connection" \
    ipv4.method manual \
    ipv4.addresses "$ip/$prefix" \
    ipv4.gateway "$gateway" \
    ipv4.dns "$dns"
  printf 'NetworkManager-Verbindung vorbereitet: %s (Sicherung: %s)\n' "$connection" "$dump"
}

configure_netplan() {
  local ip="$1" prefix="$2" gateway="$3" dns="$4" target tmp
  command -v netplan >/dev/null 2>&1 || return 1
  [[ -d /etc/netplan ]] || return 1
  [[ ! -d "/sys/class/net/$NETWORK_INTERFACE/wireless" ]] || return 1
  target=/etc/netplan/99-pi-init-static.yaml
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Managed by pi-init. Changes take effect after reboot or 'netplan apply'.
network:
  version: 2
  ethernets:
    ${NETWORK_INTERFACE}:
      dhcp4: false
      addresses:
        - ${ip}/${prefix}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
          - ${dns}
EOF
  install_if_changed "$tmp" "$target" 0600
  if ! netplan generate; then
    if [[ -f "${target}${BACKUP_SUFFIX}" ]]; then
      cp -a -- "${target}${BACKUP_SUFFIX}" "$target"
    else
      rm -f -- "$target"
    fi
    netplan generate || true
    fail "Netplan-Konfiguration war ungültig und wurde automatisch zurückgerollt."
  fi
  printf 'Netplan-Konfiguration validiert; noch nicht angewendet.\n'
}

configure_dhcpcd() {
  local ip="$1" prefix="$2" gateway="$3" dns="$4" target=/etc/dhcpcd.conf tmp
  [[ -f "$target" ]] || return 1
  tmp="$(mktemp)"
  awk '
    /^# BEGIN pi-init static network$/ {skip=1; next}
    /^# END pi-init static network$/ {skip=0; next}
    !skip {print}
  ' "$target" >"$tmp"
  cat >>"$tmp" <<EOF

# BEGIN pi-init static network
interface ${NETWORK_INTERFACE}
static ip_address=${ip}/${prefix}
static routers=${gateway}
static domain_name_servers=${dns}
# END pi-init static network
EOF
  install_if_changed "$tmp" "$target" 0644
  printf 'dhcpcd-Konfiguration vorbereitet; Dienst wird während SSH nicht neu gestartet.\n'
}

configure_network() {
  section "Netzwerk"
  local candidate answer gateway prefix=24 dns backend=""
  NETWORK_INTERFACE="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  gateway="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  [[ -n "$NETWORK_INTERFACE" ]] || fail "Aktives Netzwerkinterface konnte nicht ermittelt werden."
  [[ -n "$gateway" ]] || gateway=192.168.0.1
  dns="$gateway"
  candidate="$(candidate_ip)"
  printf 'Aktives Interface: %s, Gateway: %s\n' "$NETWORK_INTERFACE" "$gateway"
  printf 'Der Vorschlag ist nur per Ping/Neighbor-Tabelle geprüft und keine Garantie gegen IP-Konflikte.\n'
  while true; do
    answer="$(ask "Statische IPv4-Adresse oder 'dhcp'" "$candidate")"
    if [[ "${answer,,}" == dhcp || "${answer,,}" == d ]]; then
      printf 'DHCP wird beibehalten; vorhandene Netzwerkkonfiguration wird nicht verändert.\n'
      SUMMARY_OK+=("Netzwerk: DHCP/unverändert")
      return
    fi
    valid_ipv4 "$answer" && break
    printf 'Ungültige IPv4-Adresse.\n'
  done
  STATIC_NETWORK_REQUESTED=1
  STATIC_IP="$answer"
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    configure_networkmanager "$STATIC_IP" "$prefix" "$gateway" "$dns" && backend=NetworkManager
  fi
  if [[ -z "$backend" ]] && command -v netplan >/dev/null 2>&1; then
    configure_netplan "$STATIC_IP" "$prefix" "$gateway" "$dns" && backend=Netplan
  fi
  if [[ -z "$backend" ]]; then
    configure_dhcpcd "$STATIC_IP" "$prefix" "$gateway" "$dns" && backend=dhcpcd
  fi
  if [[ -z "$backend" ]]; then
    STATIC_NETWORK_REQUESTED=0
    SUMMARY_WARN+=("Statische IP nicht eingerichtet: kein unterstütztes Netzwerk-Backend erkannt")
    TODO+=("IP $STATIC_IP manuell auf $NETWORK_INTERFACE konfigurieren")
    return
  fi
  SUMMARY_OK+=("Statische IP $STATIC_IP/24 über $backend für den nächsten Neustart vorbereitet")
  TODO+=("DHCP-Reservierung eintragen und den Pi nach Abschluss neu starten")
}

configure_service_metrics() {
  section "Optionale systemd-Metriken"
  local input unit tmp
  printf 'Optional können ausgewählte Units überwacht werden, z.B. ssh.service,cups.service.\n'
  read -r -p "Units, durch Komma getrennt (Enter = keine): " input
  tmp="$(mktemp)"
  tr ',' '\n' <<<"$input" | while IFS= read -r unit; do
    unit="${unit//[[:space:]]/}"
    [[ -z "$unit" ]] && continue
    if [[ "$unit" =~ ^[A-Za-z0-9_.@:-]+\.(service|timer|socket|mount)$ ]]; then
      printf '%s\n' "$unit"
    else
      printf 'WARNUNG: Ungültige Unit wird ignoriert: %s\n' "$unit" >&2
    fi
  done >"$tmp"
  sort -u -o "$tmp" "$tmp"
  install_if_changed "$tmp" /etc/pi-init/monitor-services.conf 0644
}

configure_node_exporter() {
  section "Node Exporter und Pi-Metriken"
  local defaults_tmp metrics_tmp service_tmp timer_tmp tmpfiles_tmp args current
  install -d -m 0755 "$TEXTFILE_DIR"

  current=""
  if [[ -r /etc/default/prometheus-node-exporter ]]; then
    current="$(sed -n 's/^ARGS=//p' /etc/default/prometheus-node-exporter | tail -n 1)"
    current="${current#\"}"
    current="${current%\"}"
    current="${current#\'}"
    current="${current%\'}"
    current="$(sed -E 's#--collector.textfile.directory(=| )[[:graph:]]+##g; s#--web.listen-address(=| )[[:graph:]]+##g' <<<"$current")"
  fi
  args="$current --collector.textfile.directory=$TEXTFILE_DIR --web.listen-address=:9100"
  args="$(xargs <<<"$args")"
  defaults_tmp="$(mktemp)"
  if [[ -r /etc/default/prometheus-node-exporter ]]; then
    awk -v args="$args" '
      /^ARGS=/ {
        if (!written) print "ARGS=\"" args "\""
        written=1
        next
      }
      { print }
      END { if (!written) print "ARGS=\"" args "\"" }
    ' /etc/default/prometheus-node-exporter >"$defaults_tmp"
  else
    printf 'ARGS="%s"\n' "$args" >"$defaults_tmp"
  fi
  install_if_changed "$defaults_tmp" /etc/default/prometheus-node-exporter 0644

  tmpfiles_tmp="$(mktemp)"
  printf 'd %s 0755 root root - -\n' "$TEXTFILE_DIR" >"$tmpfiles_tmp"
  install_if_changed "$tmpfiles_tmp" /etc/tmpfiles.d/pi-init-node-exporter.conf 0644
  systemd-tmpfiles --create /etc/tmpfiles.d/pi-init-node-exporter.conf

  metrics_tmp="$(mktemp)"
  cat >"$metrics_tmp" <<'METRICS'
#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_DIR="/run/node-exporter-textfile"
OUTPUT_FILE="$OUTPUT_DIR/pi.prom"
SERVICE_FILE="/etc/pi-init/monitor-services.conf"
install -d -m 0755 "$OUTPUT_DIR"
TMP_FILE="$(mktemp "$OUTPUT_DIR/.pi.prom.XXXXXX")"
trap 'rm -f -- "$TMP_FILE"' EXIT

metric_bool() {
  printf '%s %d\n' "$1" "$2" >>"$TMP_FILE"
}

escape_label() {
  sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' <<<"$1" | tr -d '\n' | sed 's/\\n$//'
}

if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  awk '{printf "# HELP pi_cpu_temperature_celsius Raspberry Pi CPU temperature.\n# TYPE pi_cpu_temperature_celsius gauge\npi_cpu_temperature_celsius %.3f\n", $1 / 1000}' \
    /sys/class/thermal/thermal_zone0/temp >>"$TMP_FILE"
fi

printf '# HELP pi_vcgencmd_available Whether vcgencmd is available.\n# TYPE pi_vcgencmd_available gauge\n' >>"$TMP_FILE"
throttled=""
if command -v vcgencmd >/dev/null 2>&1; then
  metric_bool pi_vcgencmd_available 1
  throttled="$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=0x//p')"
else
  metric_bool pi_vcgencmd_available 0
fi

if [[ "$throttled" =~ ^[0-9a-fA-F]+$ ]]; then
  value=$((16#$throttled))
  printf '# HELP pi_undervoltage_current Current under-voltage flag.\n# TYPE pi_undervoltage_current gauge\n' >>"$TMP_FILE"
  metric_bool pi_undervoltage_current $(((value >> 0) & 1))
  printf '# HELP pi_undervoltage_since_boot Under-voltage has occurred since boot.\n# TYPE pi_undervoltage_since_boot gauge\n' >>"$TMP_FILE"
  metric_bool pi_undervoltage_since_boot $(((value >> 16) & 1))
  printf '# HELP pi_throttled_current Current throttling flag.\n# TYPE pi_throttled_current gauge\n' >>"$TMP_FILE"
  metric_bool pi_throttled_current $(((value >> 2) & 1))
  printf '# HELP pi_throttled_since_boot Throttling has occurred since boot.\n# TYPE pi_throttled_since_boot gauge\n' >>"$TMP_FILE"
  metric_bool pi_throttled_since_boot $(((value >> 18) & 1))
fi

printf '# HELP pi_ntp_synchronized Whether systemd reports synchronized time.\n# TYPE pi_ntp_synchronized gauge\n' >>"$TMP_FILE"
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
  metric_bool pi_ntp_synchronized 1
else
  metric_bool pi_ntp_synchronized 0
fi

if [[ -r "$SERVICE_FILE" ]]; then
  printf '# HELP pi_systemd_unit_active Whether a selected systemd unit is active.\n# TYPE pi_systemd_unit_active gauge\n' >>"$TMP_FILE"
  while IFS= read -r unit; do
    [[ -z "$unit" || "$unit" == \#* ]] && continue
    active=0
    systemctl is-active --quiet "$unit" && active=1
    printf 'pi_systemd_unit_active{unit="%s"} %d\n' "$(escape_label "$unit")" "$active" >>"$TMP_FILE"
  done <"$SERVICE_FILE"
fi

chmod 0644 "$TMP_FILE"
mv -f -- "$TMP_FILE" "$OUTPUT_FILE"
trap - EXIT
METRICS
  install_if_changed "$metrics_tmp" /usr/local/sbin/pi-prometheus-metrics 0755

  service_tmp="$(mktemp)"
  cat >"$service_tmp" <<'EOF'
[Unit]
Description=Collect Raspberry Pi metrics for Prometheus textfile collector
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-prometheus-metrics
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/run/node-exporter-textfile
EOF
  install_if_changed "$service_tmp" /etc/systemd/system/pi-prometheus-metrics.service 0644

  timer_tmp="$(mktemp)"
  cat >"$timer_tmp" <<'EOF'
[Unit]
Description=Refresh Raspberry Pi Prometheus metrics

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=15s
RandomizedDelaySec=5s
Persistent=false
Unit=pi-prometheus-metrics.service

[Install]
WantedBy=timers.target
EOF
  install_if_changed "$timer_tmp" /etc/systemd/system/pi-prometheus-metrics.timer 0644

  systemctl daemon-reload
  systemctl enable --now prometheus-node-exporter.service
  systemctl restart prometheus-node-exporter.service
  systemctl enable --now pi-prometheus-metrics.timer
  systemctl start pi-prometheus-metrics.service
  SUMMARY_OK+=("Node Exporter und Textfile Collector eingerichtet")
  SUMMARY_OK+=("Pi-Metrik-Timer aktiviert; Metriken liegen flüchtig im RAM")
}

configure_firewall() {
  section "Firewall"
  if command -v ufw >/dev/null 2>&1 && ufw status | head -n 1 | grep -q 'Status: active'; then
    if ! ufw status | grep -Eq '9100/tcp.*192\.168\.0\.0/24'; then
      ufw allow from 192.168.0.0/24 to any port 9100 proto tcp comment 'pi-init node exporter'
    fi
    SUMMARY_OK+=("UFW erlaubt Port 9100 aus 192.168.0.0/24")
  else
    printf 'Keine aktive UFW-Firewall erkannt; keine Regeländerung nötig.\n'
  fi
}

validate_monitoring() {
  section "Abschlussprüfung Monitoring"
  local failed=0 endpoint response_tmp
  if systemctl is-active --quiet prometheus-node-exporter.service; then
    printf 'OK: Node Exporter läuft.\n'
  else
    printf 'FEHLER: Node Exporter läuft nicht.\n'
    failed=1
  fi
  if ss -ltn | awk '{print $4}' | grep -Eq '(^|:|\])9100$'; then
    printf 'OK: Port 9100 lauscht lokal.\n'
  else
    printf 'FEHLER: Kein Listener auf Port 9100 gefunden.\n'
    failed=1
  fi
  endpoint="http://127.0.0.1:9100/metrics"
  response_tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "$endpoint" -o "$response_tmp" || failed=1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$response_tmp" "$endpoint" || failed=1
  else
    failed=1
  fi
  grep -q '^pi_' "$response_tmp" || failed=1
  rm -f -- "$response_tmp"
  if [[ "$failed" -eq 0 ]]; then
    printf 'OK: Zusätzliche Pi-Metriken werden über /metrics ausgegeben.\n'
    SUMMARY_OK+=("Monitoring-Prüfung erfolgreich: Dienst, Port 9100 und Pi-Metriken")
  else
    fail "Mindestens eine Monitoring-Prüfung ist fehlgeschlagen. Details stehen direkt oberhalb."
  fi
}

print_summary() {
  section "Zusammenfassung"
  local item mac reservation_host
  for item in "${SUMMARY_OK[@]}"; do printf 'OK: %s\n' "$item"; done
  for item in "${SUMMARY_WARN[@]}"; do printf 'WARNUNG: %s\n' "$item"; done
  if [[ "$STATIC_NETWORK_REQUESTED" -eq 1 ]]; then
    mac="$(cat "/sys/class/net/$NETWORK_INTERFACE/address" 2>/dev/null || printf 'MAC_UNBEKANNT')"
    reservation_host="${NEW_HOSTNAME:-$(hostname)}"
    printf '\nDHCP-Reservierung (Beispielzeile für deinen DHCP-Server):\n'
    printf '%s,%s,%s,24h\n' "$mac" "$STATIC_IP" "$reservation_host"
  fi
  if ((${#TODO[@]})); then
    printf '\nNoch zu tun:\n'
    for item in "${TODO[@]}"; do printf '  - %s\n' "$item"; done
  else
    printf '\nKeine manuellen Restarbeiten erkannt.\n'
  fi
  printf '\nLogdatei: %s\n' "$LOG_FILE"
}

main() {
  printf 'pi-init gestartet: %s\n' "$(date --iso-8601=seconds)"
  detect_platform
  detect_target_user
  configure_hostname
  select_packages
  install_packages
  configure_unattended_upgrades
  install_ssh_key
  configure_network
  configure_service_metrics
  configure_node_exporter
  configure_firewall
  validate_monitoring
  print_summary
}

main "$@"
