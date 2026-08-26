<#
.SYNOPSIS
    Audits GitHub repository access for all repositories in an organization
    that are visible to the supplied PAT.

.DESCRIPTION
    For every repository visible to the supplied PAT, the script:

    1. Retrieves teams assigned to the repository.
    2. Verifies expected team-slug and role mappings.
    3. Identifies missing teams.
    4. Identifies teams with an unexpected permission.
    5. Optionally identifies unexpected teams.
    6. Identifies users assigned directly to the repository.
    7. Produces detailed CSV reports and a repository-level summary.

    The script does not make any changes to GitHub.

.PARAMETER Organization
    The GitHub organization login.

.PARAMETER TeamRoleMappings
    Hashtable containing team slugs and their expected repository roles.

    Example:
        @{
            "americas-am-devs" = "admin"
            "americas-am-readers" = "pull"
        }

    Accepted canonical roles:
        pull
        triage
        push
        maintain
        admin

    Friendly aliases are also accepted:
        read  -> pull
        write -> push

.PARAMETER Token
    GitHub personal access token.

    If omitted, the script checks the GITHUB_TOKEN environment variable.

.PARAMETER OutputPath
    Directory where CSV and JSON results will be written.

.PARAMETER IncludeArchived
    Includes archived repositories. By default, archived repositories are
    inventoried but skipped from access compliance evaluation.

.PARAMETER FlagUnexpectedTeams
    Flags repository teams that were not included in TeamRoleMappings.

.PARAMETER RepositoryNamePattern
    Optional wildcard filter for repository names.

    Examples:
        "api*"
        "web*"
        "*"

.EXAMPLE
    $expectedTeams = @{
        "americas-am-devs"   = "admin"
        "americas-am-readers" = "pull"
    }

    .\Audit-GitHubRepositoryAccess.ps1 `
        -Organization "Tester" `
        -TeamRoleMappings $expectedTeams `
        -FlagUnexpectedTeams

.EXAMPLE
    $secureToken = Read-Host "GitHub PAT" -AsSecureString

    .\Audit-GitHubRepositoryAccess.ps1 `
        -Organization "Tester" `
        -TeamRoleMappings @{
            "americas-am-devs" = "admin"
            "am-developers"    = "push"
        } `
        -Token $secureToken `
        -RepositoryNamePattern "api*"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Organization,

    [Parameter()]
    [ValidateNotNull()]
    [hashtable]$TeamRoleMappings,

    [Parameter()]
    [SecureString]$Token,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (
        Join-Path -Path $PWD -ChildPath (
            "GitHubAccessAudit_{0}_{1}" -f
            $Organization,
            (Get-Date -Format "yyyyMMdd_HHmmss")
        )
    ),

    [Parameter()]
    [switch]$IncludeArchived,

    [Parameter()]
    [switch]$FlagUnexpectedTeams,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryNamePattern = "*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ApiBaseUri = "https://api.github.com"
$script:ApiVersion = "2022-11-28"
$script:RequestCount = 0

function ConvertFrom-SecureStringToPlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SecureString]$SecureValue
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $SecureValue
    )

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function ConvertTo-CanonicalGitHubRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Role
    )

    switch ($Role.Trim().ToLowerInvariant()) {
        "read"     { return "pull" }
        "pull"     { return "pull" }
        "triage"   { return "triage" }
        "write"    { return "push" }
        "push"     { return "push" }
        "maintain" { return "maintain" }
        "admin"    { return "admin" }

        default {
            throw "Unsupported GitHub role '$Role'. " +
                  "Use pull, read, triage, push, write, maintain, or admin."
        }
    }
}

function Get-GitHubPermissionRank {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Role
    )

    switch (ConvertTo-CanonicalGitHubRole -Role $Role) {
        "pull"     { return 1 }
        "triage"   { return 2 }
        "push"     { return 3 }
        "maintain" { return 4 }
        "admin"    { return 5 }
    }
}

function Test-GitHubRoleCompliance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ActualRole,

        [Parameter(Mandatory)]
        [string]$ExpectedRole
    )

    $actualCanonical = ConvertTo-CanonicalGitHubRole -Role $ActualRole
    $expectedCanonical = ConvertTo-CanonicalGitHubRole -Role $ExpectedRole

    return $actualCanonical -eq $expectedCanonical
}

function Invoke-GitHubApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter()]
        [ValidateSet("GET", "HEAD")]
        [string]$Method = "GET",

        [Parameter()]
        [switch]$AllowNotFound
    )

    try {
        $script:RequestCount++

        return Invoke-RestMethod `
            -Uri $Uri `
            -Method $Method `
            -Headers $script:GitHubHeaders 
    }
    catch {
        $statusCode = $null
        $responseBody = $null

        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }

        try {
            $responseBody = $_.ErrorDetails.Message
        }
        catch {
            $responseBody = $null
        }

        $message = "GitHub API request failed. Method: $Method. " +
                   "URI: $Uri. Status: $statusCode."

        if ($responseBody) {
            $message += " Response: $responseBody"
        }

        throw $message
    }
}

function Get-GitHubPagedResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri
    )

    $page = 1
    $results = [System.Collections.Generic.List[object]]::new()
    $separator = if ($Uri.Contains("?")) { "&" } else { "?" }

    do {
        $pagedUri = "{0}{1}per_page=100&page={2}" -f $Uri, $separator, $page
        $pageResults = @(Invoke-GitHubApi -Uri $pagedUri)

        foreach ($item in $pageResults[0]) {
            $results.Add($item)
        }

        $page++
    }
    while ($pageResults[0].Count -eq 100)

    return $results.ToArray()
}

function Get-RateLimitWarning {
    [CmdletBinding()]
    param()

    try {
        $rateLimit = Invoke-GitHubApi -Uri "$script:ApiBaseUri/rate_limit"
        $remaining = $rateLimit.resources.core.remaining
        $limit = $rateLimit.resources.core.limit
        $resetDate = [DateTimeOffset]::FromUnixTimeSeconds(
            [long]$rateLimit.resources.core.reset
        ).LocalDateTime

        return [pscustomobject]@{
            Limit     = $limit
            Remaining = $remaining
            ResetTime = $resetDate
        }
    }
    catch {
        Write-Warning "Unable to retrieve the GitHub API rate limit: $($_.Exception.Message)"
        return $null
    }
}

# Resolve token without placing it in source code.
if (-not $Token) {
    $Token = Read-Host -Prompt "Enter GitHub token (input hidden)" -AsSecureString

    $plainTextToken = ConvertFrom-SecureStringToPlainText -SecureValue $Token
}
else {
    $plainTextToken = ConvertFrom-SecureStringToPlainText -SecureValue $Token
}

$script:GitHubHeaders = @{
    Accept                 = "application/vnd.github+json"
    Authorization          = "Bearer $plainTextToken"
    "X-GitHub-Api-Version" = $script:ApiVersion
    "User-Agent"           = "PowerShell-GitHub-Repository-Access-Auditor"
}

# Normalize team mappings and make slug comparisons case-insensitive.
$normalizedTeamMappings = @{}

foreach ($mapping in $TeamRoleMappings.GetEnumerator()) {
    $teamSlug = ([string]$mapping.Key).Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($teamSlug)) {
        throw "A team mapping contains an empty team slug."
    }

    $normalizedTeamMappings[$teamSlug] =
        ConvertTo-CanonicalGitHubRole -Role ([string]$mapping.Value)
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

$repositoryResults = [System.Collections.Generic.List[object]]::new()
$teamResults = [System.Collections.Generic.List[object]]::new()
$directAccessResults = [System.Collections.Generic.List[object]]::new()
$errorResults = [System.Collections.Generic.List[object]]::new()

try {
    # Confirm which identity the token represents.
    $authenticatedUser = Invoke-GitHubApi -Uri "$script:ApiBaseUri/user"

    Write-Host ""
    Write-Host "GitHub repository access audit" -ForegroundColor Cyan
    Write-Host "Organization : $Organization"
    Write-Host "Token user   : $($authenticatedUser.login)"
    Write-Host "Output path  : $OutputPath"
    Write-Host ""

    # This returns repositories in the organization that the PAT can see.
    $repositoriesUri = "$script:ApiBaseUri/orgs/$Organization/repos" +
                       "?type=all&sort=full_name&direction=asc"

    $repositories = @(
        Get-GitHubPagedResults -Uri $repositoriesUri |
            Where-Object { $_.name -like $RepositoryNamePattern }
    )

    Write-Host (
        "The PAT can see {0} matching repositories in organization '{1}'." -f
        $repositories.Count,
        $Organization
    ) -ForegroundColor Cyan

    $repositoryNumber = 0

    foreach ($repository in $repositories) {
        $repositoryNumber++

        Write-Progress `
            -Activity "Auditing GitHub repository access" `
            -Status "$repositoryNumber of $($repositories.Count): $($repository.name)" `
            -PercentComplete (
                ($repositoryNumber / [Math]::Max(1, $repositories.Count)) * 100
            )

        $repositoryName = $repository.name
        $repositoryFullName = $repository.full_name
        $repositoryUrl = $repository.html_url
        $isArchived = [bool]$repository.archived

        $missingTeamCount = 0
        $roleMismatchCount = 0
        $unexpectedTeamCount = 0
        $directUserCount = 0
        $repositoryErrorCount = 0
        $repositoryNotes = [System.Collections.Generic.List[string]]::new()

        if ($isArchived -and -not $IncludeArchived) {
            $repositoryResults.Add([pscustomobject]@{
                Repository          = $repositoryName
                FullName            = $repositoryFullName
                RepositoryUrl       = $repositoryUrl
                Visibility          = $repository.visibility
                Archived            = $isArchived
                AuditStatus         = "SkippedArchived"
                IsCompliant         = $null
                MissingTeams        = 0
                RoleMismatches      = 0
                UnexpectedTeams     = 0
                DirectUsers         = 0
                Errors              = 0
                Notes               = "Archived repository was skipped."
            })

            continue
        }

        try {
            $encodedOwner = [Uri]::EscapeDataString($repository.owner.login)
            $encodedRepo = [Uri]::EscapeDataString($repository.name)

            # Retrieve teams currently assigned to the repository.
            $teamsUri = "$script:ApiBaseUri/repos/$encodedOwner/$encodedRepo/teams"
            $assignedTeams = @(Get-GitHubPagedResults -Uri $teamsUri)

            $assignedTeamsBySlug = @{}

            foreach ($team in $assignedTeams) {
                $actualSlug = ([string]$team.slug).ToLowerInvariant()
                $actualRole = ConvertTo-CanonicalGitHubRole `
                    -Role ([string]$team.permission)

                $assignedTeamsBySlug[$actualSlug] = $team

                $isExpectedTeam = $normalizedTeamMappings.ContainsKey(
                    $actualSlug
                )

                $expectedRole = if ($isExpectedTeam) {
                    $normalizedTeamMappings[$actualSlug]
                }
                else {
                    $null
                }

                $roleMatches = if ($isExpectedTeam) {
                    Test-GitHubRoleCompliance `
                        -ActualRole $actualRole `
                        -ExpectedRole $expectedRole
                }
                else {
                    $null
                }

                $finding = if (-not $isExpectedTeam) {
                    if ($FlagUnexpectedTeams) {
                        $unexpectedTeamCount++
                        "UnexpectedTeam"
                    }
                    else {
                        "AdditionalTeam"
                    }
                }
                elseif (-not $roleMatches) {
                    $roleMismatchCount++
                    "RoleMismatch"
                }
                else {
                    "Compliant"
                }

                $teamResults.Add([pscustomobject]@{
                    Repository       = $repositoryName
                    FullName         = $repositoryFullName
                    RepositoryUrl    = $repositoryUrl
                    TeamName         = $team.name
                    TeamSlug         = $actualSlug
                    ExpectedRole     = $expectedRole
                    ActualRole       = $actualRole
                    ActualRoleRank   = Get-GitHubPermissionRank -Role $actualRole
                    IsExpectedTeam   = $isExpectedTeam
                    RoleMatches      = $roleMatches
                    Finding          = $finding
                    TeamUrl          = $team.html_url
                })
            }

            # Add one finding for every required team that is absent.
            foreach ($expectedMapping in $normalizedTeamMappings.GetEnumerator()) {
                $expectedSlug = $expectedMapping.Key
                $expectedRole = $expectedMapping.Value

                if (-not $assignedTeamsBySlug.ContainsKey($expectedSlug)) {
                    $missingTeamCount++

                    $teamResults.Add([pscustomobject]@{
                        Repository       = $repositoryName
                        FullName         = $repositoryFullName
                        RepositoryUrl    = $repositoryUrl
                        TeamName         = $null
                        TeamSlug         = $expectedSlug
                        ExpectedRole     = $expectedRole
                        ActualRole       = $null
                        ActualRoleRank   = $null
                        IsExpectedTeam   = $true
                        RoleMatches      = $false
                        Finding          = "MissingTeam"
                        TeamUrl          = $null
                    })
                }
            }

            # affiliation=direct prevents normal team-inherited users from
            # appearing as direct repository collaborators.
            $directCollaboratorsUri =
                "$script:ApiBaseUri/repos/$encodedOwner/$encodedRepo/" +
                "collaborators?affiliation=direct"

            $directCollaborators = @(
                Get-GitHubPagedResults -Uri $directCollaboratorsUri
            )

            foreach ($collaborator in $directCollaborators) {
                $directUserCount++

                $actualRole = if ($collaborator.role_name) {
                    [string]$collaborator.role_name
                }
                elseif ($collaborator.permissions.admin) {
                    "admin"
                }
                elseif ($collaborator.permissions.maintain) {
                    "maintain"
                }
                elseif ($collaborator.permissions.push) {
                    "push"
                }
                elseif ($collaborator.permissions.triage) {
                    "triage"
                }
                elseif ($collaborator.permissions.pull) {
                    "pull"
                }
                else {
                    "unknown"
                }

                $directAccessResults.Add([pscustomobject]@{
                    Repository        = $repositoryName
                    FullName          = $repositoryFullName
                    RepositoryUrl     = $repositoryUrl
                    UserLogin         = $collaborator.login
                    UserType          = $collaborator.type
                    RepositoryRole    = $actualRole
                    UserUrl           = $collaborator.html_url
                    Finding           = "DirectUserAccess"
                    RecommendedAction = "Review and replace with team access."
                })
            }
        }
        catch {
            $repositoryErrorCount++
            $repositoryNotes.Add($_.Exception.Message)

            $errorResults.Add([pscustomobject]@{
                Repository    = $repositoryName
                FullName      = $repositoryFullName
                RepositoryUrl = $repositoryUrl
                ErrorMessage  = $_.Exception.Message
                AuditTime     = Get-Date
            })
        }

        $isCompliant = (
            $missingTeamCount -eq 0 -and
            $roleMismatchCount -eq 0 -and
            $directUserCount -eq 0 -and
            $repositoryErrorCount -eq 0 -and
            (
                -not $FlagUnexpectedTeams -or
                $unexpectedTeamCount -eq 0
            )
        )

        $repositoryResults.Add([pscustomobject]@{
            Repository          = $repositoryName
            FullName            = $repositoryFullName
            RepositoryUrl       = $repositoryUrl
            Visibility          = $repository.visibility
            Archived            = $isArchived
            AuditStatus         = if ($repositoryErrorCount -gt 0) {
                                      "Error"
                                  }
                                  else {
                                      "Audited"
                                  }
            IsCompliant         = $isCompliant
            MissingTeams        = $missingTeamCount
            RoleMismatches      = $roleMismatchCount
            UnexpectedTeams     = $unexpectedTeamCount
            DirectUsers         = $directUserCount
            Errors              = $repositoryErrorCount
            Notes               = $repositoryNotes -join " | "
        })
    }

    Write-Progress `
        -Activity "Auditing GitHub repository access" `
        -Completed

    $repositoryCsv = Join-Path $OutputPath "RepositorySummary.csv"
    $teamCsv = Join-Path $OutputPath "TeamAccessFindings.csv"
    $directAccessCsv = Join-Path $OutputPath "DirectUserAccess.csv"
    $errorCsv = Join-Path $OutputPath "Errors.csv"
    $jsonPath = Join-Path $OutputPath "GitHubAccessAudit.json"

    $repositoryResults |
        Sort-Object FullName |
        Export-Csv -Path $repositoryCsv -NoTypeInformation -Encoding utf8

    $teamResults |
        Sort-Object FullName, TeamSlug |
        Export-Csv -Path $teamCsv -NoTypeInformation -Encoding utf8

    $directAccessResults |
        Sort-Object FullName, UserLogin |
        Export-Csv -Path $directAccessCsv -NoTypeInformation -Encoding utf8

    if ($errorResults.Count -gt 0) {
        $errorResults |
            Sort-Object FullName |
            Export-Csv -Path $errorCsv -NoTypeInformation -Encoding utf8
    }

    $rateLimit = Get-RateLimitWarning

    $compliantRepositories = @(
        $repositoryResults | Where-Object { $_.IsCompliant -eq $true }
    ).Count

    $nonCompliantRepositories = @(
        $repositoryResults | Where-Object { $_.IsCompliant -eq $false }
    ).Count

    $skippedRepositories = @(
        $repositoryResults |
            Where-Object { $_.AuditStatus -eq "SkippedArchived" }
    ).Count

    $auditOutput = [ordered]@{
        AuditMetadata = [ordered]@{
            Organization          = $Organization
            TokenUser             = $authenticatedUser.login
            AuditDate             = Get-Date
            RepositoryNamePattern = $RepositoryNamePattern
            IncludeArchived       = [bool]$IncludeArchived
            FlagUnexpectedTeams   = [bool]$FlagUnexpectedTeams
            GitHubApiVersion      = $script:ApiVersion
            ApiRequestCount       = $script:RequestCount
        }
        ExpectedTeamRoles = $normalizedTeamMappings
        Summary = [ordered]@{
            VisibleRepositories      = $repositories.Count
            CompliantRepositories    = $compliantRepositories
            NonCompliantRepositories = $nonCompliantRepositories
            SkippedRepositories      = $skippedRepositories
            MissingTeamFindings      = @(
                $teamResults |
                    Where-Object { $_.Finding -eq "MissingTeam" }
            ).Count
            RoleMismatchFindings     = @(
                $teamResults |
                    Where-Object { $_.Finding -eq "RoleMismatch" }
            ).Count
            UnexpectedTeamFindings   = @(
                $teamResults |
                    Where-Object { $_.Finding -eq "UnexpectedTeam" }
            ).Count
            DirectUserFindings       = $directAccessResults.Count
            Errors                   = $errorResults.Count
        }
        RateLimit = $rateLimit
        Repositories = $repositoryResults
        Teams = $teamResults
        DirectUsers = $directAccessResults
        Errors = $errorResults
    }

    $auditOutput |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $jsonPath -Encoding utf8

    Write-Host ""
    Write-Host "Audit complete" -ForegroundColor Green
    Write-Host "Visible repositories      : $($repositories.Count)"
    Write-Host "Compliant repositories    : $compliantRepositories"
    Write-Host "Noncompliant repositories : $nonCompliantRepositories"
    Write-Host "Skipped repositories      : $skippedRepositories"
    Write-Host "Direct user assignments   : $($directAccessResults.Count)"
    Write-Host "Repository errors         : $($errorResults.Count)"
    Write-Host ""
    Write-Host "Reports:"
    Write-Host "  $repositoryCsv"
    Write-Host "  $teamCsv"
    Write-Host "  $directAccessCsv"
    Write-Host "  $jsonPath"

    if ($errorResults.Count -gt 0) {
        Write-Host "  $errorCsv"
    }

    if ($rateLimit) {
        Write-Host ""
        Write-Host (
            "GitHub API rate limit remaining: {0} of {1}. Reset: {2}" -f
            $rateLimit.Remaining,
            $rateLimit.Limit,
            $rateLimit.ResetTime
        )
    }

    # Return repository results to the PowerShell pipeline.
    return $repositoryResults
}
finally {
    # Remove the plaintext token and authorization header from the session.
    $plainTextToken = $null
    $script:GitHubHeaders = $null
}