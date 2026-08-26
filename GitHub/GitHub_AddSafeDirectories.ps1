
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string[]]$Directories,

    [switch]$Expand,

    [switch]$Recurse,
        
    [ValidateSet('None', 'Error', 'Warning', 'Information', 'Verbose', 'Debug', 'All')]
    [string]$LogLevel = 'Information',

    [switch]$Silent,

    [switch]$Test
)
    
begin {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Effective logging level (can be overridden by -Silent)
    if ($Silent.IsPresent) {
        $script:EffectiveLogLevel = 'None'
    }
    else {
        $script:EffectiveLogLevel = $LogLevel
    }

    function Write-Log {
        param(
            [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug')]
            [string]$Level = 'Information',
            [string]$Message,
            [switch]$Always
        )

        if ($Always.IsPresent) {
            Write-Host $Message
            return
        }

        $levels = @{ 'None' = 0; 'Error' = 1; 'Warning' = 2; 'Information' = 3; 'Verbose' = 4; 'Debug' = 5; 'All' = 5 }

        if (-not $script:EffectiveLogLevel) { $script:EffectiveLogLevel = 'Information' }

        $cfg = $levels[$script:EffectiveLogLevel]
        $msg = $levels[$Level]

        if ($msg -le $cfg) {
            switch ($Level) {
                'Error' { Write-Error -Message $Message }
                'Warning' { Write-Warning -Message $Message }
                'Information' { Write-Host $Message -ForegroundColor Green }
                'Verbose' { Write-Host $Message -ForegroundColor Cyan }
                'Debug' { Write-Host $Message -ForegroundColor Magenta }
                default { Write-Host $Message -ForegroundColor White }
            }
        }
    }


    function Add-GitSafeDirectory {
        param(
            [string]$Directory,
            [switch]$Expand,
            [switch]$Recurse,
            [switch]$Test
        )

        try {
            if ($Recurse.IsPresent) {
                Write-Log -Level 'Information' -Message "Recursively adding '$Directory' and its subdirectories to Git safe directories..."
                Get-ChildItem -Path $Directory -Directory -Recurse | ForEach-Object {
                    Write-Log -Level 'Information' -Message "Adding '$($_.FullName)' to Git safe directories..."
                    if (-not $Test.IsPresent) {
                        git config --global --add safe.directory "$($_.FullName)"
                    }
                    Write-Log -Level 'Information' -Message "Successfully added '$($_.FullName)' to Git safe directories."
                }
            }

            elseif ($Expand.IsPresent) {
                Get-ChildItem -Path $Directory -Directory | ForEach-Object {
                    Write-Log -Level 'Information' -Message "Adding '$($_.FullName)' to Git safe directories..."
                    if (-not $Test.IsPresent) {
                        git config --global --add safe.directory "$($_.FullName)"
                    }
                    Write-Log -Level 'Information' -Message "Successfully added '$($_.FullName)' to Git safe directories."
                }
            }
            else {
                Write-Log -Level 'Information' -Message "Adding '$Directory' to Git safe directories..."
                if (-not $Test.IsPresent) {
                    git config --global --add safe.directory "$Directory"
                }
                Write-Log -Level 'Information' -Message "Successfully added '$Directory' to Git safe directories."
            }
        }
        catch {
            Write-Log -Level 'Error' -Message "Failed to add '$Directory' to Git safe directories: $_"
        }
    }
}
    
process {
    Write-Progress -Activity "Adding Git Safe Directories" -Status "Processing directories..." -PercentComplete 0
    Write-Log -Level 'Debug' -Message "Directories to add: $($Directories -join ', ')"

    $total = $Directories.Count
    $current = 0

    foreach ($dir in $Directories) {
        Write-Progress  -Activity "Adding Git Safe Directories" `
            -Status "Processing $current of $total" `
            -PercentComplete (($current / $total) * 100) `
            -CurrentOperation "Adding '$dir' to Git safe directories..."
        try {

            Add-GitSafeDirectory -Directory $dir -Recurse:$Recurse.IsPresent -Expand:$Expand.IsPresent -Test:$Test.IsPresent
        }
        catch {
            Write-Log -Level 'Error' -Message "Failed to add '$dir' to Git safe directories: $_"
        }
        finally {
            $current++
        }
    }
}
    
end {
    Write-Progress -Activity "Adding Git Safe Directories" -Status "Completed." -PercentComplete 100
}
