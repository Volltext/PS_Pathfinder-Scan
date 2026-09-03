# PS_Pathfinder-Scan

Ein PowerShell-Tool, das ein IPv4-Netz per Ping scannt und für erreichbare
Geräte den Hostnamen per Reverse-DNS ermittelt. Das Ergebnis wird als CSV-Datei
gespeichert.

## Voraussetzungen

- **PowerShell 7 oder neuer** (Windows, Linux oder macOS).
- **Keine Internetverbindung nötig.** Das Skript verwendet ausschließlich in
  PowerShell 7 / .NET enthaltene Bordmittel (`Test-Connection`,
  `System.Net.Dns`) — es wird kein Modul aus der PowerShell Gallery
  nachinstalliert. Das Skript läuft damit auch vollständig air-gapped, ohne
  jeglichen Zugriff nach außen.
- Die Reverse-DNS-Auflösung nutzt den auf dem System konfigurierten
  DNS-Resolver (z.B. einen internen DNS-Server). Ist keiner erreichbar oder
  hat ein Host keinen PTR-Eintrag, wird der Hostname einfach als `-`
  ausgegeben — das Skript bricht dadurch nicht ab.

## Nutzung

```powershell
./Invoke-PathfinderScan.ps1 -Network 192.168.1.0/24
```

Wird das Skript ohne `-Network`-Parameter aufgerufen, fragt PowerShell
automatisch danach:

```
PS> ./Invoke-PathfinderScan.ps1
Geben Sie Werte für die folgenden Parameter an:
Network: 192.168.1.0/24
```

Während des Scans wird ein Fortschrittsbalken angezeigt; danach folgt eine
kurze Zusammenfassung und der Pfad der erzeugten CSV-Datei.

### Beispiele

```powershell
# Einfacher Scan eines /24-Netzes
./Invoke-PathfinderScan.ps1 -Network 192.168.1.0/24

# Größeres Netz, höherer Parallelitätsgrad, eigener Ausgabepfad
./Invoke-PathfinderScan.ps1 -Network 10.0.0.0/23 -ThrottleLimit 128 -OutputPath ./ergebnis.csv -Force
```

## Parameter

| Parameter         | Beschreibung                                                                 | Standard                             |
|--------------------|-------------------------------------------------------------------------------|---------------------------------------|
| `-Network`         | Zu scannendes Netz in CIDR-Notation, z.B. `192.168.1.0/24` (Pflichtangabe)     | –                                     |
| `-OutputPath`      | Pfad der CSV-Ausgabedatei                                                     | `PathfinderScan_<Zeitstempel>.csv`    |
| `-TimeoutSeconds`  | Ping-Timeout pro Host in Sekunden                                            | `1`                                   |
| `-ThrottleLimit`   | Maximale Anzahl gleichzeitig gepingter Hosts                                 | `64`                                  |
| `-Force`           | Erlaubt Scans von Netzen mit mehr als 4096 Hosts (größer als `/20`)           | aus                                   |

## Ausgabe

Die CSV-Datei enthält drei Spalten:

| IPAddress    | Reachable | Hostname       |
|--------------|-----------|----------------|
| 192.168.1.1  | Yes       | router.local   |
| 192.168.1.2  | No        | -              |

## Bekannte Einschränkungen

- Nur IPv4 wird unterstützt.
- Ein Host, der ICMP-Pings per Firewall blockiert, erscheint als `No`
  (nicht erreichbar), auch wenn er tatsächlich läuft — das lässt sich mit
  einem reinen Ping-Ansatz nicht umgehen.
- Netze größer als `/20` (mehr als 4096 Hosts) erfordern den Schalter
  `-Force`, da ein Scan dieser Größe entsprechend lange dauert.
