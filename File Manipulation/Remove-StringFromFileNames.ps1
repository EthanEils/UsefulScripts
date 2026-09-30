param (
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,

    [Parameter(Mandatory=$true)]
    [string]$StringToRemove
)

# Verify folder exists
if (-not (Test-Path $FolderPath)) {
    Write-Error "Folder does not exist: $FolderPath"
    exit 1
}

# Process all files in the folder
Get-ChildItem -Path $FolderPath -File | ForEach-Object {

    $OldName = $_.Name
    $NewName = $OldName.Replace($StringToRemove, "")

    # Skip if no change is needed
    if ($OldName -eq $NewName) {
        return
    }

    $NewFullPath = Join-Path $_.DirectoryName $NewName

    # Check for filename collisions
    if (Test-Path $NewFullPath) {
        Write-Warning "Skipping '$OldName' because '$NewName' already exists."
        return
    }

    Rename-Item -Path $_.FullName -NewName $NewName

    Write-Host "Renamed:"
    Write-Host "  $OldName"
    Write-Host "  -> $NewName"
}