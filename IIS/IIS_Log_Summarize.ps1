
<#
.SYNOPSIS
  Aggregate IIS/W3C log files by cs-method and cs-uri-stem with status-range counts.

.DESCRIPTION
  Parses .log files that may contain repeated "#Fields:" headers. Dynamically maps columns
  based on each occurrence of the header. Aggregates counts grouped by (cs-method, cs-uri-stem)
  and outputs Total, 2xx, 3xx, 4xx, 5xx counts.

.PARAMETER Path
  The root path or file path(s) to scan. Defaults to current directory.

.PARAMETER Recurse
  If provided, searches for *.log files recursively under Path.

.PARAMETER OutputCsv
  Path to write the CSV summary. If omitted, defaults to .\log-agg-summary.csv in the current directory.

.PARAMETER ShowTable
  If provided, also writes a formatted table to the console.

.EXAMPLE
  .\IIS_Log_Summarize.ps1 -Path "C:\Logs\IIS" -Recurse -OutputCsv "C:\Logs\iis-summary.csv" -ShowTable

.NOTES
  - Designed for W3C-format logs where fields are space-delimited.
  - Handles multiple "#Fields:" headers within the same file.
  - Skips lines starting with "#", except for parsing "#Fields:".

#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Path = @("..\Storage\IIS Logs"),

    [switch] $Recurse,

    [string] $KnownIpsCsv = ".\KnownIps.csv",

    [switch] $NoDns,

    [datetime] $StartTime,

    [datetime] $EndTime,
    
    [string[]] $Method,
    
    [string[]] $Status,

    [int] $Top = 0,
    
    [string[]] $ExcludeUriStem,

    [switch] $ByClientIp,

    [switch] $ByUriStem,

    [switch] $ShowTable,

    [switch] $OutputCsv,

    [string] $OutputCsvPath = "$(Join-Path -Path (Get-Location) -ChildPath 'log-agg-summary.csv')"
)

function Get-FieldMap {
    param(
        [string] $fieldsLine
    )
    # fieldsLine is the line AFTER '#Fields:' label (already trimmed)
    # Return: [ordered] hashtable mapping field name -> index
    $map = [ordered]@{}
    $fields = $fieldsLine -split '\s+'
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $map[$fields[$i]] = $i
    }
    return $map
}

function Get-StatusBucket {
    param(
        [int] $Status
    )
    if ($Status -ge 200 -and $Status -le 299) { return 'S2xx' }
    elseif ($Status -ge 300 -and $Status -le 399) { return 'S3xx' }
    elseif ($Status -ge 400 -and $Status -le 499) { return 'S4xx' }
    elseif ($Status -ge 500 -and $Status -le 599) { return 'S5xx' }
    else { return $null }
}

function Assert-IsPrivateIp {
    param(
        [string] $ip
    )
    try {
        $addr = [System.Net.IPAddress]::Parse($ip)
    }
    catch {
        return $false
    }
    if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $addr.GetAddressBytes()
    if ($b[0] -eq 10) { return $true }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true }
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
    return $false
}

function Assert-MatchesStatusFilter {
    param(
        [int] $status,
        [string[]] $filters
    )
    if (-not $filters -or $filters.Count -eq 0) { return $true }
    foreach ($f in $filters) {
        if ($f -match '^\s*(\d{3})\s*$') {
            if ($status -eq [int]$Matches[1]) { return $true }
        }
        elseif ($f -match '^\s*(\d{3})\s*-\s*(\d{3})\s*$') {
            $low = [int]$Matches[1]; $high = [int]$Matches[2]
            if ($status -ge $low -and $status -le $high) { return $true }
        }
        else {
            # try numeric parse
            $n = $null
            if ([int]::TryParse($f, [ref]$n)) {
                if ($status -eq $n) { return $true }
            }
        }
    }
    return $false
}



# Resolve files
$files = @()

if (Test-Path $Path) {
    if ((Get-Item $Path).PSIsContainer) {
        Write-Host "Scanning directory: $Path (Recurse: $Recurse)"
        $files += Get-ChildItem -Path $Path -Filter *.log -File -Recurse:$Recurse
    }
    else {
        # If user passed file(s) directly
        if ($Path -like '*.log') {
            Write-Host "Adding file: $Path"
            $files += Get-Item $Path    
        }
    }
}
else {
    Write-Warning "Path not found: $Path"
}

if ($files.Count -eq 0) {
    Write-Error "No .log files found for the given path(s)."
    exit 1
}

Write-Host "Found $($files.Count) .log files to process."

# Aggregation dictionary:
# Key: "<cs-method>||<cs-uri-stem>"
# Value: PSObject with fields for counts
$agg = @{}

# Cache for reverse DNS lookups when using -ByClientIp
$hostCache = @{}

# Load known IP->Host mappings from CSV if provided
if ($KnownIpsCsv) {
    if (Test-Path $KnownIpsCsv) {
        try {
            $mappingRows = Import-Csv -Path $KnownIpsCsv
            foreach ($row in $mappingRows) {
                $ip = $null
                if ($row.PSObject.Properties.Name -contains 'ip') { $ip = $row.ip }
                elseif ($row.PSObject.Properties.Name -contains 'c-ip') { $ip = $row.'c-ip' }
                elseif ($row.PSObject.Properties.Name -contains 'IP') { $ip = $row.IP }
                elseif ($row.PSObject.Properties.Name -contains 'ClientIP') { $ip = $row.ClientIP }

                $logHost = $null
                if ($row.PSObject.Properties.Name -contains 'host') { $logHost = $row.host }
                elseif ($row.PSObject.Properties.Name -contains 'Host') { $logHost = $row.Host }
                elseif ($row.PSObject.Properties.Name -contains 'hostname') { $logHost = $row.hostname }

                if ($ip -and $logHost) {
                    $hostCache[$ip] = $logHost
                }
            }
        }
        catch {
            Write-Warning "Failed to import KnownIpsCsv '$KnownIpsCsv': $_"
        }
    }
    else {
        Write-Warning "Known IPs CSV not found: $KnownIpsCsv"
    }
}

# Current field map (reset whenever a new '#Fields:' line is encountered)
[hashtable] $fieldMap = $null

# Process files
foreach ($file in $files) {
    Write-Host "Processing: $($file.FullName)"

    # Stream line-by-line to keep memory usage modest
    $reader = [System.IO.File]::OpenText($file.FullName)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Length -eq 0) { continue }

            if ($line.StartsWith('#')) {
                # Header or comment. Only act on '#Fields:'
                if ($line -match '^\#Fields:\s*(.+)$') {
                    $fieldsPart = $Matches[1].Trim()
                    $fieldMap = Get-FieldMap -fieldsLine $fieldsPart

                    # Cache numeric indexes for commonly used fields to avoid repeated dictionary lookups
                    $fieldIdx = @{}
                    foreach ($name in @('date', 'time', 'c-ip', 'cs-uri-stem', 'cs-method', 'sc-status')) {
                        if ($fieldMap.ContainsKey($name)) { $fieldIdx[$name] = [int]$fieldMap[$name] }
                    }
                }
                continue
            }

            if (-not $fieldMap) {
                # No field map yet; cannot parse data lines
                continue
            }

            # W3C logs are space-delimited; cs-uri-stem should not contain spaces.
            # Use -split '\s+' to be robust to multiple spaces.
            $cols = $line -split '\s+'
            # Validate we have enough columns
            if ($cols.Count -lt $fieldMap.Count) {
                Write-Host "Skipping line due to column count mismatch: $line"
                continue
            }

            # Determine which fields we need based on switches
            $needClient = $ByClientIp
            # We need URI stem when ByUriStem is set, or when neither switch is set (default groups by uri stem)
            $needUri = $ByUriStem -or (-not $ByClientIp -and -not $ByUriStem)
            # We need method only in the default mode (no switches)
            $needMethod = (-not $ByClientIp -and -not $ByUriStem)

            # Build required fields list and validate header using cached numeric indexes
            $required = @()
            if ($needClient) { $required += 'c-ip' }
            if ($needUri) { $required += 'cs-uri-stem' }
            if ($needMethod) { $required += 'cs-method' }
            $required += 'sc-status'

            $missing = $required | Where-Object { -not $fieldIdx.ContainsKey($_) }
            if ($missing.Count -gt 0) { continue }

            # Extract values for the fields we need using numeric indexes
            if ($needClient) { $clientIp = $cols[$fieldIdx['c-ip']] }
            if ($needUri) { $uriStem = $cols[$fieldIdx['cs-uri-stem']] }
            if ($needMethod) { $method = $cols[$fieldIdx['cs-method']] }
            $statusRaw = $cols[$fieldIdx['sc-status']]

            # Parse status
            [int]$status = $null
            if (-not [int]::TryParse($statusRaw, [ref]$status)) {
                # Non-integer status; skip
                continue
            }

            # If time filtering requested, require date/time and filter
            if ($StartTime -or $EndTime) {
                $dateStr = $cols[$fieldMap['date']]
                $timeStr = $cols[$fieldMap['time']]
                try {
                    $lineDt = [datetime]::Parse("$dateStr $timeStr")
                }
                catch {
                    continue
                }
                if ($StartTime -and $lineDt -lt $StartTime) { continue }
                if ($EndTime -and $lineDt -gt $EndTime) { continue }
            }

            $bucket = Get-StatusBucket -Status $status

            # Apply method/status filters if provided
            if ($Method -and $Method.Count -gt 0) {
                # ensure we have method value (extract if not present earlier)
                if (-not $method -and $fieldIdx.ContainsKey('cs-method')) { $method = $cols[$fieldIdx['cs-method']] }
                if (-not ($Method -contains $method)) { continue }
            }
            if ($Status -and $Status.Count -gt 0) {
                if (-not (Assert-MatchesStatusFilter -status $status -filters $Status)) { continue }
            }

            # Exclude specific uri stems if requested (support wildcards)
            if ($ExcludeUriStem -and $ExcludeUriStem.Count -gt 0 -and $uriStem) {
                $shouldExclude = $false
                foreach ($pattern in $ExcludeUriStem) {
                    if ($pattern -eq $uriStem) { $shouldExclude = $true; break }
                    # Use -like to support wildcards (case-insensitive)
                    if ($uriStem -like $pattern) { $shouldExclude = $true; break }
                }
                if ($shouldExclude) { continue }
            }

            # Build aggregation key/object depending on mode
            if ($ByClientIp -and $ByUriStem) {
                $key = "$clientIp||$uriStem"
                if (-not $agg.ContainsKey($key)) {
                    $obj = [PSCustomObject]@{
                        'c-ip'        = $clientIp
                        'cs-uri-stem' = $uriStem
                        'Total'       = 0
                        'S2xx'        = 0
                        'S3xx'        = 0
                        'S4xx'        = 0
                        'S5xx'        = 0
                    }
                    $agg[$key] = $obj
                }
            }
            elseif ($ByClientIp) {
                $key = $clientIp
                if (-not $agg.ContainsKey($key)) {
                    $obj = [PSCustomObject]@{
                        'c-ip'  = $clientIp
                        'Total' = 0
                        'S2xx'  = 0
                        'S3xx'  = 0
                        'S4xx'  = 0
                        'S5xx'  = 0
                    }
                    $agg[$key] = $obj
                }
            }
            elseif ($ByUriStem) {
                $key = $uriStem
                if (-not $agg.ContainsKey($key)) {
                    $obj = [PSCustomObject]@{
                        'cs-uri-stem' = $uriStem
                        'Total'       = 0
                        'S2xx'        = 0
                        'S3xx'        = 0
                        'S4xx'        = 0
                        'S5xx'        = 0
                    }
                    $agg[$key] = $obj
                }
            }
            else {
                $key = "$method||$uriStem"
                if (-not $agg.ContainsKey($key)) {
                    $obj = [PSCustomObject]@{
                        'cs-method'   = $method
                        'cs-uri-stem' = $uriStem
                        'Total'       = 0
                        'S2xx'        = 0
                        'S3xx'        = 0
                        'S4xx'        = 0
                        'S5xx'        = 0
                    }
                    $agg[$key] = $obj
                }
            }

            $agg[$key].Total++
            if ($bucket) {
                $agg[$key].$bucket++
            }
        }
    }
    finally {
        $reader.Close()
        $reader.Dispose()
    }
}

# Emit CSV
if ($ByClientIp) {
    if ($ByUriStem) {
        $rows = $agg.Values |
        Sort-Object -Property 'c-ip', 'cs-uri-stem' |
        Select-Object 'c-ip', 'cs-uri-stem', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
    }
    else {
        $rows = $agg.Values |
        Sort-Object -Property 'c-ip' |
        Select-Object 'c-ip', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
    }

    # Attempt reverse DNS lookup for each client IP (cached), but skip private IP ranges
    foreach ($r in $rows) {
        $ip = $r.'c-ip'
        if (-not $hostCache.ContainsKey($ip)) {
            if (-not $NoDns -and -not (Assert-IsPrivateIp $ip)) {
                try {
                    $hn = [System.Net.Dns]::GetHostEntry($ip).HostName
                }
                catch {
                    $hn = $null
                }
                $hostCache[$ip] = $hn
            }
            else {
                # Do not resolve private or disabled DNS; leave null unless provided in KnownIpsCsv
                $hostCache[$ip] = $null
            }
        }
        if (-not $NoDns) {
            $r | Add-Member -NotePropertyName 'Host' -NotePropertyValue $hostCache[$ip] -Force
        }
    }

    # Apply Top-N cutoff after selection if requested
    if ($Top -gt 0) {
        $rows = $rows | Sort-Object -Property 'Total' -Descending | Select-Object -First $Top
    }
    
    # Ensure Host is included in exported/printed columns
    if ($ByUriStem) {
        if (-not $NoDns) {
            $rows = $rows | Select-Object 'c-ip', 'Host', 'cs-uri-stem', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
        }
        else {
            $rows = $rows | Select-Object 'c-ip', 'cs-uri-stem', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
        }
    }
    else {
        if (-not $NoDns) {
            $rows = $rows | Select-Object 'c-ip', 'Host', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
        }
        else {
            $rows = $rows | Select-Object 'c-ip', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
        }
    }
}
elseif ($ByUriStem) {
    $rows = $agg.Values |
    Sort-Object -Property 'cs-uri-stem' |
    Select-Object 'cs-uri-stem', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
}
else {
    $rows = $agg.Values |
    Sort-Object -Property 'cs-method', 'cs-uri-stem' |
    Select-Object 'cs-method', 'cs-uri-stem', 'Total', 'S2xx', 'S3xx', 'S4xx', 'S5xx'
}

$dir = Split-Path -Parent $OutputCsvPath
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if ($OutputCsv) {
    $rows | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Summary written to: $OutputCsvPath"
}

if ($ShowTable) {
    $rows | Format-Table -AutoSize
}


