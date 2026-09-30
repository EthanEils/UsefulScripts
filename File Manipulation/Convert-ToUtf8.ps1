<#
.SYNOPSIS
Converts files with a selected BOM-identified source encoding to a target encoding.
Source encodings: UTF8BOM, UTF16LE, UTF16BE, UTF32LE.
Target encodings: UTF8, UTF8BOM, UTF16LE, UTF16BE, UTF32LE, ASCII.

.PARAMETER FolderPath
The folder containing files to process.

.PARAMETER Recurse
Processes files in subfolders.

.PARAMETER FromEncoding
The required source encoding. Files without the matching byte order mark (BOM) are skipped.
Available values: UTF8BOM, UTF16LE, UTF16BE, UTF32LE. Default: UTF16LE.

.PARAMETER ToEncoding
The encoding written to converted files.
Available values: UTF8, UTF8BOM, UTF16LE, UTF16BE, UTF32LE, ASCII. Default: UTF8.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,

    [switch]$Recurse,

    [ValidateSet('UTF8BOM', 'UTF16LE', 'UTF16BE', 'UTF32LE')]
    [string]$FromEncoding = 'UTF16LE',

    [ValidateSet('UTF8', 'UTF8BOM', 'UTF16LE', 'UTF16BE', 'UTF32LE', 'ASCII')]
    [string]$ToEncoding = 'UTF8'
)

function Get-TextEncoding {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    switch ($Name) {
        'UTF8'    { return [System.Text.UTF8Encoding]::new($false) }
        'UTF8BOM' { return [System.Text.UTF8Encoding]::new($true) }
        'UTF16LE' { return [System.Text.Encoding]::Unicode }
        'UTF16BE' { return [System.Text.Encoding]::BigEndianUnicode }
        'UTF32LE' { return [System.Text.UTF32Encoding]::new($false, $true) }
        'ASCII'   { return [System.Text.Encoding]::ASCII }
    }
}

function Test-FileHasEncodingPreamble {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FilePath,

        [Parameter(Mandatory=$true)]
        [System.Text.Encoding]$Encoding
    )

    $preamble = $Encoding.GetPreamble()
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)

    if ($bytes.Length -lt $preamble.Length) {
        return $false
    }

    for ($byteIndex = 0; $byteIndex -lt $preamble.Length; $byteIndex++) {
        if ($bytes[$byteIndex] -ne $preamble[$byteIndex]) {
            return $false
        }
    }

    return $true
}

$sourceEncoding = Get-TextEncoding -Name $FromEncoding
$targetEncoding = Get-TextEncoding -Name $ToEncoding

# Get files
$files = if ($Recurse) {
    Get-ChildItem -Path $FolderPath -File -Recurse
}
else {
    Get-ChildItem -Path $FolderPath -File
}

foreach ($file in $files) {
    try {
        if (-not (Test-FileHasEncodingPreamble -FilePath $file.FullName -Encoding $sourceEncoding)) {
            Write-Host "Skipping: $($file.FullName) (does not have a $FromEncoding BOM)"
            continue
        }

        Write-Host "Converting: $($file.FullName) ($FromEncoding -> $ToEncoding)"

        $content = [System.IO.File]::ReadAllText(
            $file.FullName,
            $sourceEncoding
        )

        [System.IO.File]::WriteAllText(
            $file.FullName,
            $content,
            $targetEncoding
        )
    }
    catch {
        Write-Warning "Failed to process $($file.FullName): $_"
    }
}

Write-Host "Conversion complete."