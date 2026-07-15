# Grafana

`raspberry-pi-fleet.json` ist ein wiederverwendbares Flotten-Dashboard. Es
erwartet den Prometheus-Job `raspberry-pi` und das von `pi-init` ausgegebene
Target-Label `host`.

## Einmaliger Import

In Grafana unter **Dashboards → New → Import** die JSON-Datei hochladen und die
zentrale Prometheus-Datenquelle auswählen. Neue Pis erscheinen nach dem
Anlegen ihrer `file_sd`-Targetdatei automatisch in der Variablen **Pi**; ein
neues Dashboard ist nicht nötig.

## Provisionierung

Für eine dateibasierte Provisionierung kann das Verzeichnis in den
Grafana-Container beziehungsweise nach `/var/lib/grafana/dashboards` gemountet
und mit folgendem Provider geladen werden:

```yaml
apiVersion: 1
providers:
  - name: homelab
    type: file
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

Als detaillierte Einzelhostansicht kann zusätzlich das Grafana-Dashboard
**Node Exporter Full (ID 1860)** importiert werden.
