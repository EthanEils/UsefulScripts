<#
.SYNOPSIS
List GitHub repositories for an organization with optional team or user filter,
including security alert counts and key metadata.

.PARAMETER Org
(Required) GitHub organization login (e.g., Tester)

.PARAMETER Token
(Required) GitHub Personal Access Token with scopes: read:org, repo, security_events

.PARAMETER TeamSlug
(Optional) Organization team slug to filter repositories visible to that team

.PARAMETER UserLogin
(Optional) User login to filter repositories visible to the AUTHENTICATED USER (the PAT owner)
within the specified organization. NOTE: This uses /user/repos for the PAT owner and filters
to the org; it does NOT impersonate another user.

.PARAMETER AsJson
(Optional) If set, outputs JSON; otherwise shows a formatted table in the terminal.

.EXAMPLE
.\GitHub_Repo_Export.ps1 -Org my-org -Token $env:GITHUB_TOKEN -TeamSlug platform-eng

.EXAMPLE
.\GitHub_Repo_Export.ps1 -Org my-org -Token $env:GITHUB_TOKEN -UserLogin ethan -AsJson

.EXAMPLE
.\GitHub_Repo_Export.ps1 -Org my-org -Token $env:GITHUB_TOKEN
# Returns ALL org repos (if you have permission) with metadata + security counts.

.NOTES
- Uses GraphQL for bulk repo metadata (topics, archived, visibility, default branch last commit).
- Uses REST for Dependabot, Code Scanning, and Secret Scanning alert counts.
- Handles pagination for both GraphQL and REST.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Org,

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $false)]
    [string]$TeamSlug,

    [Parameter(Mandatory = $false)]
    [string]$UserLogin,

    [switch]$AsJson
)

# -----------------------------
# Configuration & HTTP helpers
# -----------------------------
$GitHubRestBase = "https://api.github.com"
$GraphQLEndpoint = "$GitHubRestBase/graphql"
$CommonRestHeaders = @{
    "Authorization"        = "Bearer $Token"
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$CommonGraphQLHeaders = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
}

function Invoke-GHGraphQL {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][hashtable]$Variables
    )
    $body = @{
        query     = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 10

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $GraphQLEndpoint -Headers $CommonGraphQLHeaders -Body $body
        if ($resp.errors) {
            $msg = ($resp.errors | ConvertTo-Json -Depth 10)
            throw "GraphQL error(s): $msg"
        }
        return $resp.data
    }
    catch {
        throw "GraphQL request failed: $($_.Exception.Message)"
    }
}

function Invoke-GHRestPagedCount {
    <#
    Calls a REST endpoint that returns an ARRAY per page and sums item counts across pages.
    Returns 0 on 404/410 or when feature not enabled.
  #>
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )
    $total = 0
    $next = $Url
    try {
        while ($next) {
            $response = Invoke-WebRequest -Method Get -Uri $next -Headers $CommonRestHeaders -UseBasicParsing -ErrorAction Stop
            if ($response.Content) {
                $arr = $response.Content | ConvertFrom-Json
                if ($null -ne $arr) {
                    if ($arr -is [array]) { $total += $arr.Count }
                    else {
                        # Some endpoints could theoretically return objects; be defensive.
                        $total += 0
                    }
                }
            }
            # Parse Link header for pagination
            $link = $response.Headers['Link']
            if ($link -and $link -match '<([^>]+)>;\s*rel="next"') {
                $next = $Matches[1]
            }
            else {
                $next = $null
            }
        }
    }
    catch {
        # Treat as 0 if endpoint not enabled or 404/410. Handle 403 (forbidden)
        $resp = $_.Exception.Response
        if ($resp) {
            $status = $resp.StatusCode.Value__
            if ($status -in 404, 410) {
                return 0
            }
            if ($status -eq 403) {
                Write-Warning "REST call returned 403 Forbidden for ${Url}. This commonly means the PAT lacks required scopes (e.g. 'security_events' or 'repo' for private repos), or SAML/SSO/org policy is blocking access. Verify the token scopes and that the token is authorized for the organization."
                return 0
            }
        }

        Write-Warning "REST call failed for ${Url}: $($_.Exception.Message)"
        return 0
    }
    return $total
}

function Get-AuthenticatedUserLogin {
    try {
        $me = Invoke-RestMethod -Method Get -Uri "$GitHubRestBase/user" -Headers $CommonRestHeaders -ErrorAction Stop
        return $me.login
    }
    catch {
        throw "Failed to determine authenticated user: $($_.Exception.Message)"
    }
}

# -----------------------------------
# GraphQL queries for repo metadata
# -----------------------------------

# Fetch repositories visible to a TEAM (org+team slug), with pagination.
function Get-TeamReposGraphQL {
    param(
        [Parameter(Mandatory = $true)][string]$OrgLogin,
        [Parameter(Mandatory = $true)][string]$TeamSlugParam
    )

    $q = @'
query ($org: String!, $team: String!, $endCursor: String) {
    organization(login: $org) {
        team(slug: $team) {
            repositories(
                first: 10
                after: $endCursor
                orderBy: { field: NAME, direction: ASC }
            ) {
                pageInfo {
                    hasNextPage
                    endCursor
                }
                nodes {
                    name
                    isArchived
                    visibility
                    description
                    url
                    owner {
                        login
                    }
                    repositoryTopics(first: 100) {
                        nodes {
                            topic {
                                name
                            }
                        }
                    }
                    defaultBranchRef {
                        name
                        target {
                            ... on Commit {
                                history(first: 1) {
                                    nodes {
                                        oid
                                        committedDate
                                        messageHeadline
                                        author {
                                            name
                                            email
                                            user {
                                                login
                                            }
                                        }
                                        url
                                    }
                                }
                            }
                        }
                    }
                    branches: refs(refPrefix: "refs/heads/", first: 1) {
                        totalCount
                    }
                    archivedAt
                    openPullRequests: pullRequests(
                        first: 100
                        states: OPEN
                        orderBy: { field: CREATED_AT, direction: DESC }
                    ) {
                        totalCount
                        nodes {
                            number
                            title
                            url
                            createdAt
                            author {
                                ... on User {
                                    name
                                    email
                                    login
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
'@

    $cursor = $null
    $items = @()
    while ($true) {
        $data = Invoke-GHGraphQL -Query $q -Variables @{ org = $OrgLogin; team = $TeamSlugParam; endCursor = $cursor }
        if ($null -eq $data.organization -or $null -eq $data.organization.team) {
            throw "Team '$TeamSlugParam' not found or access denied in org '$OrgLogin'."
        }
        $page = $data.organization.team.repositories
        if ($page.nodes) { $items += $page.nodes }
        if ($page.pageInfo.hasNextPage) {
            $cursor = $page.pageInfo.endCursor
        }
        else { break }
    }
    return $items
}

# Fetch ALL organization repositories (that the PAT can see).
function Get-OrgReposGraphQL {
    param([Parameter(Mandatory = $true)][string]$OrgLogin)

    $q = @'
query ($org: String!, $team: String!, $endCursor: String) {
    organization(login: $org) {
        team(slug: $team) {
            repositories(
                first: 10
                after: $endCursor
                orderBy: { field: NAME, direction: ASC }
            ) {
                pageInfo {
                    hasNextPage
                    endCursor
                }
                nodes {
                    name
                    isArchived
                    visibility
                    description
                    url
                    owner {
                        login
                    }
                    repositoryTopics(first: 100) {
                        nodes {
                            topic {
                                name
                            }
                        }
                    }
                    defaultBranchRef {
                        name
                        target {
                            ... on Commit {
                                history(first: 1) {
                                    nodes {
                                        oid
                                        committedDate
                                        messageHeadline
                                        author {
                                            name
                                            email
                                            user {
                                                login
                                            }
                                        }
                                        url
                                    }
                                }
                            }
                        }
                    }
                    branches: refs(refPrefix: "refs/heads/", first: 1) {
                        totalCount
                    }
                    archivedAt
                    openPullRequests: pullRequests(
                        first: 100
                        states: OPEN
                        orderBy: { field: CREATED_AT, direction: DESC }
                    ) {
                        totalCount
                        nodes {
                            number
                            title
                            url
                            createdAt
                            author {
                                ... on User {
                                    name
                                    email
                                    login
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
'@

    $cursor = $null
    $items = @()
    while ($true) {
        $data = Invoke-GHGraphQL -Query $q -Variables @{ org = $OrgLogin; endCursor = $cursor }
        if ($null -eq $data.organization) {
            throw "Organization '$OrgLogin' not found or access denied."
        }
        $page = $data.organization.repositories
        if ($page.nodes) { $items += $page.nodes }
        if ($page.pageInfo.hasNextPage) {
            $cursor = $page.pageInfo.endCursor
        }
        else { break }
    }
    return $items
}

# For USER filter: list repos accessible to the AUTHENTICATED USER via REST, then enrich via GraphQL in batches.
function Get-UserReposForOrg {
    param(
        [Parameter(Mandatory = $true)][string]$OrgLogin
    )
    # Gather all repos the PAT owner can access, limit to org owner==OrgLogin
    $url = "$GitHubRestBase/user/repos?per_page=100&sort=full_name&direction=asc"
    $all = @()
    $next = $url

    try {
        while ($next) {
            $resp = Invoke-WebRequest -Method Get -Uri $next -Headers $CommonRestHeaders -UseBasicParsing -ErrorAction Stop
            if ($resp.Content) {
                $page = $resp.Content | ConvertFrom-Json
                if ($page) { $all += $page }
            }
            $link = $resp.Headers['Link']
            if ($link -and $link -match '<([^>]+)>;\s*rel="next"') {
                $next = $Matches[1]
            }
            else { $next = $null }
        }
    }
    catch {
        throw "Failed to list /user/repos: $($_.Exception.Message)"
    }

    $orgRepos = $all | Where-Object { $_.owner.login -eq $OrgLogin }
    if (-not $orgRepos) { return @() }

    # Batch-enrich via GraphQL 'repository(owner:, name:)' queries (we can also use nodes(ids:), but REST gives node_id which works too).
    # We'll build batches of up to 100 repos and fetch fields in one go using aliases.
    $enriched = @()

    $batches = [System.Collections.Generic.List[object]]::new()
    $batch = @()
    foreach ($r in $orgRepos) {
        $batch += [pscustomobject]@{ owner = $r.owner.login; name = $r.name }
        if ($batch.Count -ge 50) { $batches.Add($batch); $batch = @() } # keep the GQL manageable
    }
    if ($batch.Count -gt 0) { $batches.Add($batch) }

    foreach ($b in $batches) {
        # Build a single GraphQL query with aliases per repo to reduce round-trips
        $fragments = @()
        $variables = @{}
        $i = 0
        foreach ($repo in $b) {
            $alias = "r$i"
            $varOwner = "owner$i"
            $varName = "name$i"
            $variables[$varOwner] = $repo.owner
            $variables[$varName] = $repo.name
            $fragments += @"
${alias}: repository(owner: $$varOwner, name: $$varName) {
    name
    isArchived
    visibility
    description
    url
    owner {
        login
    }
    repositoryTopics(first: 100) {
        nodes {
            topic {
                name
            }
        }
    }
    defaultBranchRef {
        name
        target {
            ... on Commit {
                history(first: 1) {
                    nodes {
                        oid
                        committedDate
                        messageHeadline
                        author {
                            name
                            email
                            user {
                                login
                            }
                        }
                        url
                    }
                }
            }
        }
    }
    branches: refs(refPrefix: "refs/heads/", first: 1) {
        totalCount
    }
    archivedAt
    openPullRequests: pullRequests(
        first: 100
        states: OPEN
        orderBy: { field: CREATED_AT, direction: DESC }
    ) {
        totalCount
        nodes {
            number
            title
            url
            createdAt
            author {
                ... on User {
                    name
                    email
                    login
                }
            }
        }
    }
}
"@
            $i++
        }

        $query = "query(" + (
            ($variables.Keys | ForEach-Object { "`$${_}: String!" }) -join ", "
        ) + ") {" + ($fragments -join "`n") + "}"

        $data = Invoke-GHGraphQL -Query $query -Variables $variables

        # Convert back into an array of repo objects by reading each alias property
        $obj = $data | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        foreach ($k in $obj.PSObject.Properties.Name) {
            $enriched += $obj.$k
        }
    }

    return $enriched
}

# --------------------------------
# Security counts per repository
# --------------------------------
function Get-RepoSecurityCounts {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Name
        , [Parameter(Mandatory = $false)][bool]$Archived = $false
    )
    if ($Archived) {
        Write-Verbose "Skipping security alert fetch for archived repository $Owner/$Name"
        $dep = 0
        $cs = 0
        $ss = 0
        return @{
            Dependabot = $dep
            CodeScan   = $cs
            SecretScan = $ss
        }
    }

    $dep = Invoke-GHRestPagedCount -Url "$GitHubRestBase/repos/$Owner/$Name/dependabot/alerts?state=open&per_page=100"
    $cs = Invoke-GHRestPagedCount -Url "$GitHubRestBase/repos/$Owner/$Name/code-scanning/alerts?state=open&per_page=100"
    $ss = Invoke-GHRestPagedCount -Url "$GitHubRestBase/repos/$Owner/$Name/secret-scanning/alerts?state=open&per_page=100"
    return @{
        Dependabot = $dep
        CodeScan   = $cs
        SecretScan = $ss
    }
}

# -----------------------------
# Main selection and retrieval
# -----------------------------

if ($TeamSlug -and $UserLogin) {
    throw "Please specify either -TeamSlug or -UserLogin, not both."
}

$repos = @()

if ($TeamSlug) {
    Write-Verbose "Fetching repositories for org '$Org' visible to team '$TeamSlug' via GraphQL…"
    $repos = Get-TeamReposGraphQL -OrgLogin $Org -TeamSlugParam $TeamSlug
}
elseif ($UserLogin) {
    $patLogin = Get-AuthenticatedUserLogin
    if ($patLogin -ne $UserLogin) {
        Write-Warning "User filter uses the authenticated user's (PAT owner) access. Your PAT owner is '$patLogin', which does not match -UserLogin '$UserLogin'. Results reflect '$patLogin' access within org '$Org'."
    }
    Write-Verbose "Fetching repositories accessible to authenticated user '$patLogin' and filtering to org '$Org'…"
    $repos = Get-UserReposForOrg -OrgLogin $Org
}
else {
    Write-Verbose "Fetching all repositories for org '$Org' (as visible to the PAT) via GraphQL…"
    $repos = Get-OrgReposGraphQL -OrgLogin $Org
}

if (-not $repos -or $repos.Count -eq 0) {
    Write-Output @()
    return
}

# Build output objects with security counts
$results = @()
$idx = 0
$tot = $repos.Count
foreach ($r in $repos) {
    $idx++
    $owner = $r.owner.login
    $name = $r.name

    # Compute fields
    $archived = [bool]$r.isArchived
    $archivedAt = $r.archivedAt
    $vis = $r.visibility
    $url = $r.url
    $desc = if ($r.description) { $r.description } else { "" }
    if ($r.repositoryTopics -and $r.repositoryTopics.nodes) {
        $topics = @($r.repositoryTopics.nodes | ForEach-Object { $_.topic.name })
    }
    else {
        $topics = @()
    }
    $lastCommit = ""
    if ($r.defaultBranchRef -and $r.defaultBranchRef.target -and $r.defaultBranchRef.target.history -and $r.defaultBranchRef.target.history.nodes -and $r.defaultBranchRef.target.history.nodes.Count -gt 0 -and $r.defaultBranchRef.target.history.nodes[0].committedDate) {
        $lastCommit = $r.defaultBranchRef.target.history.nodes[0].committedDate
    }

    $openPRcount = if ($r.openPullRequests) { $r.openPullRequests.totalCount } else { 0 }
    $branchCount = if ($r.branches) { $r.branches.totalCount } else { 0 }

    # Security counts
    Write-Verbose ("[{0}/{1}] Security counts for {2}/{3}…" -f $idx, $tot, $owner, $name)
    $sec = Get-RepoSecurityCounts -Owner $owner -Name $name -Archived $archived

    $results += [pscustomobject]@{
        Name                      = $name
        FullName                  = "$owner/$name"
        Owner                     = $owner
        Archived                  = $archived
        ArchivedDate              = $archivedAt
        LastCommitDate            = $lastCommit
        Topics                    = $topics
        DependabotAlertsCount     = $sec.Dependabot
        CodeScanningAlertsCount   = $sec.CodeScan
        SecretScanningAlertsCount = $sec.SecretScan
        TotalOpenSecurityAlerts   = $sec.Dependabot + $sec.CodeScan + $sec.SecretScan
        OpenPRCount               = $openPRcount
        BranchCount               = $branchCount
        Description               = $desc
        Visibility                = $vis
        Url                       = $url
    }
}

# Output formatting
if ($AsJson) {
    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $safeOrg = ($Org -replace '[^A-Za-z0-9_-]', '_')
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $outFileName = "github_repos_${safeOrg}_${timestamp}.json"
    $outFile = Join-Path -Path $scriptDir -ChildPath $outFileName
    $results | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding UTF8
    Write-Verbose "Wrote JSON output to $outFile"
    Write-Output $outFile
    return
}
else {
    $results |
    Select-Object Name, Owner, Archived, ArchivedDate, LastCommitDate,
    @{n = "topics"; e = { ($_.Topics -join "; ") } },
    DependabotAlertsCount, CodeScanningAlertsCount, SecretScanningAlertsCount, OpenPRCount, BranchCount, TotalOpenSecurityAlerts,
    Visibility, Url,
    @{n = "description"; e = { if ($_.description.Length -gt 80) { $_.description.Substring(0, 80) + "…" } else { $_.description } } } |
    Format-Table -AutoSize
}