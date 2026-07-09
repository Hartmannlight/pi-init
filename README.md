# pi-init

Interaktive, idempotente Ersteinrichtung für Raspberry Pi OS, Debian und Ubuntu
Server. Das Projekt richtet einen neuen Pi ein, kopiert wiederverwendbare
Hilfsskripte nach `~/scripts` und installiert ein leichtgewichtiges Monitoring
für einen **externen** Prometheus-Server.

## Schnellstart

Auf dem neuen Pi per SSH anmelden und als normaler Benutzer diesen einen Befehl
ausführen. Er installiert die kleinen Bootstrap-Voraussetzungen automatisch und
startet danach direkt die interaktive Einrichtung:

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates tar && curl -fsSL https://raw.githubusercontent.com/Hartmannlight/pi-init/main/bootstrap.sh | bash
```

Falls `curl`, `wget` und `tar` bereits vorhanden sind, genügt auch der kürzere
Befehl:

```bash
wget -qO- https://raw.githubusercontent.com/Hartmannlight/pi-init/main/bootstrap.sh | bash
```

Der Bootstrap lädt den aktuellen Stand ohne Git nach `/tmp`, erstellt
`~/scripts`, kopiert `init.sh` als `~/scripts/pi-init.sh` sowie alle Dateien aus
`scripts/` dorthin und startet anschließend:

```bash
sudo ~/scripts/pi-init.sh
```

Vorhandene, abweichende Dateien in `~/scripts` werden vor dem Überschreiben mit
einem Zeitstempel gesichert. Das Init-Skript selbst verweigert die Ausführung
ohne Root-Rechte.

Der für dieses Homelab vorgesehene öffentliche SSH-Schlüssel ist im Repository
hinterlegt. Er wird idempotent für den Benutzer ergänzt; die Passwort-Anmeldung
bleibt aktiv. Ein abweichender Schlüssel kann bei Bedarf einmalig mit
`PI_INIT_PUBLIC_KEY='ssh-ed25519 ...' sudo -E ~/scripts/pi-init.sh` übergeben
werden.

## Was eingerichtet wird

- Betriebssystemprüfung (Raspberry Pi OS/Raspbian, Debian oder Ubuntu)
- aktueller und optional neuer Hostname
- `apt update` und `apt upgrade`
- `unattended-upgrades` mit täglicher Paketlisten-Aktualisierung
- interaktive Paketauswahl; Grundausstattung ist vorausgewählt
- DHCP oder vorbereitete statische IPv4-Konfiguration
- öffentlicher SSH-Schlüssel ohne Abschalten der Passwort-Anmeldung
- Debian-Paket `prometheus-node-exporter`, systemd-Autostart und Port 9100
- Textfile Collector und Pi-Metriken per ressourcenschonendem systemd-Timer

Statische Netzwerkänderungen werden absichtlich **nicht sofort aktiviert**, da
sonst die laufende SSH-Verbindung abbrechen könnte. Sie greifen nach einem
Neustart. Unterstützt werden NetworkManager, Netplan und dhcpcd. Das Skript
schlägt aus `192.168.0.100` bis `192.168.0.119` die höchste Adresse vor, die auf
Ping und in der lokalen Neighbor-Tabelle nicht belegt erscheint. Das ist nur
eine bestmögliche Prüfung; die Adresse muss zusätzlich im DHCP-Server reserviert
werden. Am Ende wird dafür eine Zeile im Format
`MAC,IP,HOSTNAME,24h` ausgegeben.

## Paketauswahl

Vorausgewählt: `git curl wget nano tree python3 unzip ca-certificates`

Optional: `rsync zip jq htop tmux dnsutils lsof ncdu ripgrep python3-pip
python3-venv`

`prometheus-node-exporter` und `unattended-upgrades` sind Kernfunktionen und
werden unabhängig von dieser Auswahl installiert.

## Monitoring-Dateien

| Datei | Zweck |
| --- | --- |
| `/usr/local/sbin/pi-prometheus-metrics` | erzeugt Pi-spezifische Metriken |
| `/etc/pi-init/monitor-services.conf` | optionale systemd-Units, eine pro Zeile |
| `/etc/systemd/system/pi-prometheus-metrics.service` | einmaliger Metrik-Lauf |
| `/etc/systemd/system/pi-prometheus-metrics.timer` | Lauf nach Boot und alle 60 Sekunden |
| `/etc/tmpfiles.d/pi-init-node-exporter.conf` | erzeugt flüchtiges Collector-Verzeichnis |
| `/run/node-exporter-textfile/pi.prom` | atomar ersetzte Metrikdatei im RAM |
| `/etc/default/prometheus-node-exporter` | Collector- und Listen-Argumente |
| `/var/log/pi-init/pi-init-*.log` | vollständiges Protokoll jedes Init-Laufs |

Die zusätzlichen Metriken umfassen CPU-Temperatur, Verfügbarkeit von
`vcgencmd`, aktuelle/seit Boot erkannte Unterspannung und Drosselung,
NTP-Synchronisation sowie optional ausgewählte systemd-Dienste. Falls
`vcgencmd` auf einer unterstützten Installation fehlt, bleiben die übrigen
Metriken verfügbar und `pi_vcgencmd_available` zeigt den Zustand an.

Prometheus, Grafana, Alertmanager und Blackbox Exporter werden ausdrücklich
nicht installiert. Auf dem zentralen Prometheus-Server genügt beispielsweise:

```yaml
scrape_configs:
  - job_name: raspberry-pi
    static_configs:
      - targets: ['192.168.0.102:9100']
```

## Weitere Skripte

Jede ausführbare Datei, die im Repository direkt unter `scripts/` liegt, wird
beim Bootstrap direkt nach `~/scripts/` kopiert. Unterordner werden ebenfalls
übernommen. Damit lassen sich spätere, manuell auszuführende Werkzeuge ergänzen,
ohne das Init-Skript aufzublähen.

| Skript | Zweck |
| --- | --- |
| `pi-health` | zeigt Exporter-, Timer- und Pi-Metrik-Status an |
| `setup-zpl-usb-parallel.sh` | richtet USB-Parallel-ZPL-Drucker mit stabilem `/dev/zpl/<name>` ein |

`setup-zpl-usb-parallel.sh` wird bei Bedarf separat ausgeführt:

```bash
sudo ~/scripts/setup-zpl-usb-parallel.sh
```

Es lädt `usblp`, erkennt angeschlossene `/dev/usb/lp*`-Adapter und erzeugt eine
udev-Regel mit einer eindeutigen Seriennummer, wenn vorhanden. Bei Adaptern ohne
Seriennummer ist ein VID:PID-Match nur sicher, solange kein baugleicher Adapter
angeschlossen ist; bei mehreren identischen Adaptern bietet das Skript bewusst
nur die portgebundene Notlösung an. Es installiert außerdem `zpl-send`, das
gleichzeitige Raw-ZPL-Schreibzugriffe per `flock` serialisiert.

## Idempotenz und Sicherungen

Verwaltete Dateien werden nur ersetzt, wenn sich ihr Inhalt ändert. Bestehende
Konfigurationen erhalten vorher eine Sicherung mit dem Suffix
`.pi-init-backup-YYYYmmdd-HHMMSS`. SSH-Schlüssel werden nur ergänzt, wenn sie
noch nicht exakt vorhanden sind. systemd-Units und Timer werden als verwaltete
Dateien aktualisiert, nicht dupliziert.
