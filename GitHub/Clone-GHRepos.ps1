param (
    [string]$Organization ,
    [string]$TeamSlug ,
    [string]$Token ,
    [string]$DestinationRoot = ".\"
)

$GitHubRestBase = "https://api.github.com"
$GraphQLEndpoint = "$GitHubRestBase/graphql"
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


# Fetch repositories visible to a TEAM (org+team slug), with pagination.
function Get-TeamReposGraphQL {
    param(
        [Parameter(Mandatory = $true)][string]$OrgLogin,
        [Parameter(Mandatory = $true)][string]$TeamSlugParam
    )

    $q = @'
query($org: String!, $team: String!, $endCursor: String) {
    organization(login: $org) {
        team(slug: $team) {
            repositories(first: 100, after: $endCursor, orderBy: {field: NAME, direction: ASC}) {
                pageInfo { hasNextPage endCursor }
                nodes {
                    name
                    isArchived
                    visibility
                    description
                    url
                    owner { login }
                    repositoryTopics(first: 100) { nodes { topic { name } } }
                    defaultBranchRef {
                        name
                        target { ... on Commit { committedDate } }
                    }
                    archivedAt
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

function Invoke-GitHubAPI {
    param (
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Token,
        # Add configurable filters as needed, e.g., $Filters
        [hashtable]$Filters
    )

    $Headers = @{
        "Authorization" = "Bearer $Token"
    }

    # Apply filters to the URI if needed, e.g., $Uri = "$Uri&$($Filters | ForEach-Object { "$($_.Key)=$($_.Value)" } -join '&')"
    if ($Filters) {
        $filterString = ($Filters.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '&'
        $Uri = "$Uri&$filterString"
    }

    
    $total = 0
    $next = $Uri
    $results = @()

    try {
        while($next) {
            $Response = Invoke-WebRequest -Uri $next -Method $Method -Headers $Headers
            $content = $Response.Content | ConvertFrom-Json
            $results += $content
            $total += $content.Count

            # Check for pagination
            if ($Response.Headers.Link) {
                $links = $Response.Headers.Link -split ','
                $nextLink = $links | Where-Object { $_ -match 'rel="next"' }
                if ($nextLink) {
                    $next = ($nextLink -split ';')[0].Trim('<> ')
                }
                else {
                    $next = $null
                }
            }
            else {
                $next = $null
            }
        }

        return $results
    }
    catch {
        Write-Error "Failed to call GitHub API: $_"
        return $null
    }
}

function Invoke-GitHubClone {
    param (
        [string]$RepoUrl,
        [string]$DestinationPath
    )

    try {
        git clone $RepoUrl $DestinationPath
    }
    catch {
        Write-Error "Failed to clone repository: $_"
    }
}

$Repos = Get-TeamReposGraphQL -OrgLogin $Organization -TeamSlugParam $TeamSlug

if ($Repos) {
    foreach ($Repo in $Repos) {
        if ($Repo.isArchived -eq $true) {
            Write-Host "Skipping archived repository: $($Repo.name)"
            continue
        }
        
        $RepoName = $Repo.name
        $RepoUrl = $Repo.url
        $DestinationPath = Join-Path -Path $DestinationRoot -ChildPath $RepoName

        Write-Host "Cloning repository: $RepoName"
        Invoke-GitHubClone -RepoUrl $RepoUrl -DestinationPath $DestinationPath
    }
}
else {
    Write-Error "No repositories found for organization: $Organization"
}
