<#
.SYNOPSIS
    Export installed VS Code extensions to a JSON file.

.DESCRIPTION
    Exports the current list of VS Code extensions as JSON.
    Supports exporting with or without version numbers.

.PARAMETER OutputPath
    Path to write the JSON file. Defaults to ./vscode-extensions.json

.PARAMETER IncludeVersions
    Include extension versions (uses `code --list-extensions --show-versions`).

.PARAMETER Edition
    VS Code edition to target. Allowed: 'stable' (default), 'insiders'.
    Maps to 'code' or 'code-insiders' CLI.

.EXAMPLE
    .\Export-VSCodeExtensions.ps1

.EXAMPLE
    .\Export-VSCodeExtensions.ps1 -IncludeVersions -OutputPath .\my-extensions.json

.EXAMPLE
    .\Export-VSCodeExtensions.ps1 -Edition insiders
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "$(Join-Path (Get-Location) 'vscode-extensions.json')",
    [switch]$IncludeVersions,
    [ValidateSet('stable', 'insiders')]
    [string]$Edition = 'stable'
)

function Get-CodeCli {
    param([string]$Edition)
    $cli = if ($Edition -eq 'insiders') { 'code-insiders' } else { 'code' }

    # Try to resolve; if not found, still return the guessed name (may be on PATH).
    $resolved = (Get-Command $cli -ErrorAction SilentlyContinue)
    if (-not $resolved) {
        Write-Verbose "Could not resolve '$cli' with Get-Command; attempting to call it directly."
    }
    return $cli
}

try {
    $cli = Get-CodeCli -Edition $Edition

    # Verify CLI availability
    $null = & $cli --version 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "VS Code CLI '$cli' not found or not available on PATH. Open VS Code and run: 'Shell Command: Install 'code' command in PATH' (Command Palette)."
    }

    $args = @('--list-extensions')
    if ($IncludeVersions) { $args += '--show-versions' }

    $raw = & $cli @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list extensions from '$cli'."
    }

    # Transform to JSON
    # If IncludeVersions: lines look like "publisher.extension@1.2.3"
    # Else: "publisher.extension"
    $items = @()
    foreach ($line in ($raw | Where-Object { $_ -and $_.Trim() -ne '' })) {
        if ($IncludeVersions) {
            if ($line -match '^(.+?)@([\w\.-]+)$') {
                $items += [pscustomobject]@{
                    name    = $Matches[1]
                    version = $Matches[2]
                }
            } else {
                # Fallback: no version parsed — store name only
                $items += [pscustomobject]@{ name = $line; version = $null }
            }
        } else {
            $items += [pscustomobject]@{ name = $line }
        }
    }

    # Write JSON (pretty)
    $json = $items | ConvertTo-Json -Depth 4
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
    Write-Host "Exported $(($items | Measure-Object).Count) extensions to: $OutputPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}