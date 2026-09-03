#Requires -Version 7.0
<#
.SYNOPSIS
    Scannt ein IPv4-Netz per Ping und ermittelt Hostnamen erreichbarer Geräte.

.DESCRIPTION
    Invoke-PathfinderScan nimmt ein IP-Netz in CIDR-Notation (z.B. 192.168.1.0/24)
    entgegen, pingt parallel alle nutzbaren Host-Adressen in diesem Netz an und
    ermittelt für jeden antwortenden Host per Reverse-DNS-Lookup den Hostnamen.
    Das Ergebnis (IPAddress, Reachable, Hostname) wird als CSV-Datei exportiert.

    Das Skript benötigt ausschließlich lokal installierte Bestandteile von
    PowerShell 7 / .NET (Test-Connection, System.Net.Dns) und funktioniert ohne
    Internetzugriff (air-gapped-fähig). Die Reverse-DNS-Auflösung nutzt den auf
    dem System konfigurierten DNS-Resolver; ist keiner erreichbar, wird der
    Hostname einfach als "-" ausgegeben.

.PARAMETER Network
    Das zu scannende Netz in CIDR-Notation, z.B. "192.168.1.0/24".

.PARAMETER OutputPath
    Pfad der zu erzeugenden CSV-Datei. Standard: PathfinderScan_<Zeitstempel>.csv
    im aktuellen Verzeichnis.

.PARAMETER TimeoutSeconds
    Timeout pro Ping in Sekunden. Standard: 1.

.PARAMETER ThrottleLimit
    Maximale Anzahl gleichzeitig gepingter Hosts. Standard: 64.

.PARAMETER Force
    Erlaubt das Scannen von Netzen mit mehr als 4096 Hosts (größer als /20).

.EXAMPLE
    ./Invoke-PathfinderScan.ps1 -Network 192.168.1.0/24

.EXAMPLE
    ./Invoke-PathfinderScan.ps1 -Network 10.0.0.0/23 -ThrottleLimit 128 -OutputPath ./ergebnis.csv -Force

.EXAMPLE
    ./Invoke-PathfinderScan.ps1
    Startet ohne Parameter; PowerShell fragt interaktiv nach dem Netz.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
    [string]$Network,

    [string]$OutputPath = "PathfinderScan_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 1,

    [ValidateRange(1, 256)]
    [int]$ThrottleLimit = 64,

    [switch]$Force
)

$MaxHostsWithoutForce = 4096

function ConvertTo-UInt32FromIPAddress {
    param([Parameter(Mandatory)][System.Net.IPAddress]$IPAddress)

    $bytes = $IPAddress.GetAddressBytes()
    return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
}

function ConvertTo-IPAddressFromUInt32 {
    param([Parameter(Mandatory)][uint32]$Value)

    $bytes = [byte[]](
        [byte](($Value -shr 24) -band 0xFF),
        [byte](($Value -shr 16) -band 0xFF),
        [byte](($Value -shr 8) -band 0xFF),
        [byte]($Value -band 0xFF)
    )
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-CidrHostRange {
    param([Parameter(Mandatory)][string]$Cidr)

    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) {
        throw "Ungültiges Netz '$Cidr'. Erwartetes Format: a.b.c.d/prefix (0-32)."
    }

    $ipText, $prefixText = $parts
    $prefix = 0
    if (-not [int]::TryParse($prefixText, [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
        throw "Ungültige Präfixlänge in '$Cidr'. Erwartet wird eine Zahl zwischen 0 und 32."
    }

    $ipAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($ipText, [ref]$ipAddress)) {
        throw "Ungültige IP-Adresse '$ipText' in '$Cidr'."
    }
    if ($ipAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Nur IPv4-Netze werden unterstützt. '$ipText' ist keine IPv4-Adresse."
    }

    $ipValue = ConvertTo-UInt32FromIPAddress -IPAddress $ipAddress
    $maskValue = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }
    $networkValue = $ipValue -band $maskValue
    $broadcastValue = $networkValue -bor (-bnot $maskValue)

    $startValue, $endValue = switch ($prefix) {
        32 { $ipValue, $ipValue }
        31 { $networkValue, $broadcastValue }
        default { ($networkValue + 1), ($broadcastValue - 1) }
    }

    $hostCount = $endValue - $startValue + 1

    if ($hostCount -gt $MaxHostsWithoutForce -and -not $Force) {
        throw "Das Netz '$Cidr' enthält $hostCount Hosts und überschreitet die Sicherheitsgrenze von $MaxHostsWithoutForce. Nutze -Force, um den Scan trotzdem durchzuführen."
    }

    $hostIPs = for ($value = $startValue; $value -le $endValue; $value++) {
        ConvertTo-IPAddressFromUInt32 -Value $value
    }

    return $hostIPs
}

$hostIPs = Get-CidrHostRange -Cidr $Network

Write-Host "Scanne $($hostIPs.Count) Hosts in $Network mit ThrottleLimit $ThrottleLimit ..."

$progress = [hashtable]::Synchronized(@{ Done = 0; Total = $hostIPs.Count })

$job = $hostIPs | ForEach-Object -AsJob -ThrottleLimit $ThrottleLimit -Parallel {
    $ip = $_
    $reachable = Test-Connection -TargetName $ip -Count 1 -TimeoutSeconds $using:TimeoutSeconds -Quiet
    $hostname = '-'
    if ($reachable) {
        try {
            $hostname = ([System.Net.Dns]::GetHostEntry($ip)).HostName
        } catch {
            $hostname = '-'
        }
    }
    ($using:progress).Done++
    [PSCustomObject]@{
        IPAddress = $ip
        Reachable = if ($reachable) { 'Yes' } else { 'No' }
        Hostname  = $hostname
    }
}

while ($job.State -eq 'Running') {
    $pct = [int](100 * $progress.Done / $progress.Total)
    Write-Progress -Activity "Scanne $Network" -Status "$($progress.Done) / $($progress.Total) Hosts geprüft" -PercentComplete $pct
    Start-Sleep -Milliseconds 200
}
Write-Progress -Activity "Scanne $Network" -Completed

$results = Receive-Job -Job $job -Wait
Remove-Job -Job $job

$results = $results | Sort-Object { [version]($_.IPAddress) }

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$reachableCount = ($results | Where-Object Reachable -eq 'Yes').Count
$unreachableCount = $results.Count - $reachableCount

Write-Host ""
Write-Host "Scan abgeschlossen: $reachableCount erreichbar, $unreachableCount nicht erreichbar."
Write-Host "Ergebnis gespeichert unter: $OutputPath"
