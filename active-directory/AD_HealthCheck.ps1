<#
.SYNOPSIS
    Active Directory Health Check Script

.DESCRIPTION
    Runs a comprehensive, READ-ONLY health check across all Domain Controllers
    in the current domain:
      - Domain/Forest info
      - Per-DC connectivity, core services, disk space, SYSVOL/NETLOGON shares,
        time sync, DCDIAG key tests, recent Directory Service/DNS/System errors
      - Forest-wide FSMO role holders
      - Forest-wide replication summary
    Produces a color-coded console summary AND an HTML report you can save/share.

    This script makes NO configuration changes — every check is diagnostic only.

.REQUIREMENTS
    - Run from a Domain Controller, or a management workstation with the
      "RSAT: Active Directory Domain Services" feature / ActiveDirectory
      PowerShell module installed.
    - Run as a user with Domain Admins (or at least read access to all DCs,
      remote service query rights, and remote event log read rights).
    - dcdiag.exe and repadmin.exe must be available (they ship with RSAT-AD
      and natively on any DC).

.USAGE
    .\AD_HealthCheck.ps1
    .\AD_HealthCheck.ps1 -ReportPath "C:\Reports\ad_health.html"

.NOTES
    If run from a non-DC workstation, Windows Firewall on the DCs must allow
    remote service management / WMI / remote event log traffic (this is
    standard "Domain Controller" firewall profile behavior, but locked-down
    environments may need to allow it explicitly).
#>

#Requires -Modules ActiveDirectory

param(
    [string]$ReportPath = "$env:USERPROFILE\Desktop\AD_HealthCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
)

$ErrorActionPreference = 'Continue'
$script:results = @()

function Add-Result {
    param($Category, $Check, $Status, $Details)
    $script:results += [PSCustomObject]@{
        Category = $Category
        Check    = $Check
        Status   = $Status
        Details  = $Details
    }
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("  [{0}] {1}: {2}" -f $Status, $Check, $Details) -ForegroundColor $color
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Active Directory Health Check - $(Get-Date)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---- Import AD module ----
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Host "ERROR: ActiveDirectory PowerShell module not found." -ForegroundColor Red
    Write-Host "Install it with: Install-WindowsFeature RSAT-AD-PowerShell (on a server)" -ForegroundColor Red
    Write-Host "or via Optional Features > RSAT: Active Directory Module (on Win10/11)." -ForegroundColor Red
    exit 1
}

# ---- 1. Domain / Forest info ----
Write-Host "`n--- Domain / Forest Info ---" -ForegroundColor Cyan
try {
    $domain = Get-ADDomain
    $forest = Get-ADForest
    Add-Result "Environment" "Domain" "PASS" $domain.DNSRoot
    Add-Result "Environment" "Domain Functional Level" "PASS" $domain.DomainMode
    Add-Result "Environment" "Forest Functional Level" "PASS" $forest.ForestMode
} catch {
    Add-Result "Environment" "Domain/Forest Query" "FAIL" $_.Exception.Message
}

# ---- 2. Enumerate Domain Controllers ----
$dcs = @()
try {
    $dcs = Get-ADDomainController -Filter *
    Add-Result "Environment" "Domain Controllers Found" "PASS" (($dcs.Name) -join ', ')
} catch {
    Add-Result "Environment" "Domain Controller Enumeration" "FAIL" $_.Exception.Message
}

# ---- 3. Per-DC checks ----
foreach ($dc in $dcs) {
    $dcName = $dc.HostName
    Write-Host "`n--- Checking $dcName ---" -ForegroundColor Yellow

    # Connectivity
    if (Test-Connection -ComputerName $dcName -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Add-Result $dcName "Ping Connectivity" "PASS" "Reachable"
    } else {
        Add-Result $dcName "Ping Connectivity" "FAIL" "Unreachable - skipping remaining checks for this DC"
        continue
    }

    # Core AD services
    $criticalServices = 'NTDS','DNS','Netlogon','Kdc','W32Time'
    foreach ($svc in $criticalServices) {
        try {
            $s = Get-Service -ComputerName $dcName -Name $svc -ErrorAction Stop
            $status = if ($s.Status -eq 'Running') { 'PASS' } else { 'FAIL' }
            Add-Result $dcName "Service: $svc" $status $s.Status
        } catch {
            Add-Result $dcName "Service: $svc" "WARN" "Not found or inaccessible (check remote access/firewall)"
        }
    }

    # Disk space on system drive
    try {
        $disk = Get-CimInstance -ComputerName $dcName -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $freePct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
        $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
        $status = if ($freePct -lt 10) { 'FAIL' } elseif ($freePct -lt 20) { 'WARN' } else { 'PASS' }
        Add-Result $dcName "Disk Free Space (C:)" $status "$freePct% free ($freeGB GB)"
    } catch {
        Add-Result $dcName "Disk Free Space (C:)" "WARN" "Unable to query (check WMI/CIM remote access)"
    }

    # SYSVOL / NETLOGON share accessibility
    foreach ($share in 'SYSVOL','NETLOGON') {
        $path = "\\$dcName\$share"
        if (Test-Path $path -ErrorAction SilentlyContinue) {
            Add-Result $dcName "$share Share" "PASS" "Accessible"
        } else {
            Add-Result $dcName "$share Share" "FAIL" "Not accessible"
        }
    }

    # Time sync status
    try {
        $timeStatus = & w32tm /query /computer:$dcName /status 2>&1
        $srcLine = ($timeStatus | Select-String "Source:")
        if ($srcLine) {
            Add-Result $dcName "Time Source" "PASS" ($srcLine.ToString().Trim())
        } else {
            Add-Result $dcName "Time Source" "WARN" "Could not determine time source"
        }
    } catch {
        Add-Result $dcName "Time Sync" "WARN" "Unable to query w32tm"
    }

    # DCDIAG - key tests (faster than a full run)
    try {
        $dcdiagOut = & dcdiag /s:$dcName /test:Connectivity /test:Advertising /test:FrsEvent /test:DFSREvent `
                              /test:SysVolCheck /test:KccEvent /test:NetLogons /test:Replications `
                              /test:Services /test:SystemLog /test:VerifyReferences 2>&1
        $failedTests = $dcdiagOut | Select-String "failed test"
        if ($failedTests) {
            Add-Result $dcName "DCDIAG" "FAIL" (($failedTests | ForEach-Object { $_.ToString().Trim() }) -join ' | ')
        } else {
            Add-Result $dcName "DCDIAG" "PASS" "All selected tests passed"
        }
    } catch {
        Add-Result $dcName "DCDIAG" "WARN" "dcdiag.exe not available or failed to run: $($_.Exception.Message)"
    }

    # Recent critical/error events (last 24h): Directory Service, DNS Server, System
    foreach ($log in 'Directory Service','DNS Server','System') {
        try {
            $events = Get-WinEvent -ComputerName $dcName -FilterHashtable @{
                LogName   = $log
                Level     = 1,2   # 1=Critical, 2=Error
                StartTime = (Get-Date).AddHours(-24)
            } -ErrorAction Stop
            Add-Result $dcName "$log Log (last 24h)" "WARN" "$($events.Count) critical/error event(s) found"
        } catch {
            # Get-WinEvent errors out when there are zero matches - treat that as a clean pass
            Add-Result $dcName "$log Log (last 24h)" "PASS" "No critical/error events"
        }
    }
}

# ---- 4. FSMO Role Holders (forest-wide, run once) ----
Write-Host "`n--- FSMO Role Holders ---" -ForegroundColor Yellow
try {
    $fsmoOut = & netdom query fsmo 2>&1
    Add-Result "Forest-wide" "FSMO Roles" "PASS" (($fsmoOut | Where-Object { $_ -and $_ -notmatch 'command completed successfully' }) -join ' | ')
} catch {
    Add-Result "Forest-wide" "FSMO Roles" "WARN" "Unable to query via netdom"
}

# ---- 5. Replication Summary (forest-wide, run once) ----
Write-Host "`n--- Replication Summary ---" -ForegroundColor Yellow
try {
    $replOut = & repadmin /replsummary 2>&1
    $replText = $replOut -join "`n"
    # Only flag real failures: look for actual N/M pairs where N (fails) > 0.
    # (Matching header text like "fails/total" caused false positives previously.)
    $failMatches = [regex]::Matches($replText, '(\d+)\s*/\s*(\d+)')
    $hasRealFailures = $false
    foreach ($m in $failMatches) {
        if ([int]$m.Groups[1].Value -gt 0) { $hasRealFailures = $true }
    }
    if ($hasRealFailures) {
        Add-Result "Forest-wide" "Replication Summary" "WARN" "Non-zero fail count detected - review full repadmin output below"
    } else {
        Add-Result "Forest-wide" "Replication Summary" "PASS" "No replication failures (0 fails across all partner pairs)"
    }
    # Always keep the raw output for the report
    Add-Result "Forest-wide" "Replication Summary (raw)" "PASS" $replText
} catch {
    Add-Result "Forest-wide" "Replication Summary" "WARN" "repadmin.exe not available"
}

# ---- Summary ----
$passCount = @($results | Where-Object Status -eq 'PASS').Count
$warnCount = @($results | Where-Object Status -eq 'WARN').Count
$failCount = @($results | Where-Object Status -eq 'FAIL').Count

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " SUMMARY: $passCount Passed | $warnCount Warnings | $failCount Failed" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

if ($failCount -gt 0) {
    Write-Host "`nItems needing attention (FAIL):" -ForegroundColor Red
    $results | Where-Object Status -eq 'FAIL' | Format-Table Category, Check, Details -AutoSize -Wrap
}
if ($warnCount -gt 0) {
    Write-Host "`nItems worth reviewing (WARN):" -ForegroundColor Yellow
    $results | Where-Object Status -eq 'WARN' | Format-Table Category, Check, Details -AutoSize -Wrap
}

# ---- Export HTML report ----
$style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1a1a1a; }
h1 { margin-bottom: 4px; }
.meta { color: #666; margin-bottom: 20px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ddd; padding: 8px 10px; text-align: left; font-size: 13px; }
th { background-color: #1F6F5C; color: white; }
tr:nth-child(even) { background-color: #f7f7f7; }
.PASS { color: #157347; font-weight: bold; }
.WARN { color: #b8860b; font-weight: bold; }
.FAIL { color: #b00020; font-weight: bold; }
</style>
"@

$htmlBody = $results | ConvertTo-Html -Fragment -Property Category, Check, Status, Details
# Colorize status cells
$htmlBody = $htmlBody -replace '<td>PASS</td>', '<td class="PASS">PASS</td>'
$htmlBody = $htmlBody -replace '<td>WARN</td>', '<td class="WARN">WARN</td>'
$htmlBody = $htmlBody -replace '<td>FAIL</td>', '<td class="FAIL">FAIL</td>'

$html = "<html><head><title>AD Health Check Report</title>$style</head><body>" +
        "<h1>Active Directory Health Check</h1>" +
        "<p class='meta'>Generated: $(Get-Date) | Domain: $($domain.DNSRoot) | Pass: $passCount / Warn: $warnCount / Fail: $failCount</p>" +
        $htmlBody + "</body></html>"

$html | Out-File -FilePath $ReportPath -Encoding UTF8

Write-Host "`nReport saved to: $ReportPath" -ForegroundColor Green
