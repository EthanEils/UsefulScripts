<#
.SYNOPSIS
        Query GitHub for open PRs and branches for a given repository.

.DESCRIPTION
        Accepts a GitHub Personal Access Token (PAT) and repository identification (org + repo or owner/repo)
        and outputs:
                - All open pull requests with: title, author, approval state, combined commit status, check runs and status details.
                - All branches with: name, last commit author, last commit date and last commit SHA/message.

.PARAMETER Pat
        GitHub Personal Access Token. If omitted you'll be prompted securely.

.PARAMETER Org
        Organization or owner. Optional if you supply Repo as "owner/repo".

.PARAMETER Repo
        Repository name. If you provided Repo as "owner/repo" this parameter may be omitted.

.PARAMETER AsJson
        If specified, outputs results as JSON for easy consumption.

.EXAMPLE
        .\GitHub_Repo_OpenPRsAndBranches.ps1 -Pat $env:GITHUB_PAT -Org myOrg -Repo myRepo

.EXAMPLE
        .\GitHub_Repo_OpenPRsAndBranches.ps1 -Pat $env:GITHUB_PAT -Repo "myOwner/myRepo" -AsJson
#>

[CmdletBinding()]
param(
        [Parameter(Mandatory = $false)]
        [string]$Pat,

        [Parameter(Mandatory = $false)]
        [string]$Org,

        [Parameter(Mandatory = $false)]
        [string]$Repo,

        [switch]$AsJson
)

function Get-ClearTextFromSecureString {
        param([System.Security.SecureString]$ss)
        if (-not $ss) { return $null }
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Prompt for PAT if not provided
if (-not $Pat) {
        $securePat = Read-Host -Prompt "Enter GitHub PAT (input hidden)" -AsSecureString
        $Pat = Get-ClearTextFromSecureString -ss $securePat
        if (-not $Pat) {
                Write-Error "A GitHub PAT is required."
                exit 1
        }
}

# Normalize owner/repo
if (-not $Org -and $Repo -and $Repo -match "/") {
        $parts = $Repo -split "/"
        if ($parts.Length -ge 2) {
                $Org = $parts[0]
                $Repo = $parts[1]
        }
}

if (-not $Org -or -not $Repo) {
        Write-Host "Repository not provided or not parseable. Provide either -Org and -Repo, or -Repo as 'owner/repo'."
        exit 1
}

$baseUrl = "https://api.github.com"
$headers = @{
        Authorization = "token $Pat"
        Accept        = "application/vnd.github.v3+json"
        "User-Agent"  = "PowerShell-GitHubScript"
}

function Invoke-GitHubApi {
        param(
                [string]$Method = "GET",
                [string]$Url,
                [hashtable]$Headers = $headers,
                [int]$MaxRetries = 5
        )

        $attempt = 0
        while ($true) {
                try {
                        $attempt++
                        $resp = Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers -ErrorAction Stop
                        return $resp
                }
                catch [System.Net.WebException] {
                        $webEx = $_.Exception
                        if ($webEx.Response) {
                                $httpResp = $webEx.Response
                                $statusCode = ([int]$httpResp.StatusCode)
                                $retryAfter = $httpResp.Headers["Retry-After"]
                                if ($statusCode -eq 401) {
                                        throw "Unauthorized. Check PAT permissions."
                                }
                                if ($statusCode -in 429, 403 -and $retryAfter) {
                                        $wait = [int]$retryAfter
                                        Start-Sleep -Seconds ($wait + 1)
                                }
                                elseif ($statusCode -in 429, 403) {
                                        # backoff
                                        if ($attempt -ge $MaxRetries) { throw "Rate limited and max retries reached." }
                                        Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                                }
                                else {
                                        $body = ""
                                        try { $body = (New-Object System.IO.StreamReader($httpResp.GetResponseStream())).ReadToEnd() } catch {}
                                        throw "HTTP $statusCode\: $body"
                                }
                        }
                        else {
                                if ($attempt -ge $MaxRetries) { throw $_ }
                                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                        }
                }
                catch {
                        if ($attempt -ge $MaxRetries) { throw $_ }
                        Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                }
        }
}

function Get-AllPaged {
        param([string]$Url)
        $results = @()
        $next = $Url
        while ($next) {
                $response = $null
                # Use Invoke-RestMethod to also get headers via ResponseContainers
                $attempt = 0
                while ($true) {
                        try {
                                $attempt++
                                $raw = Invoke-WebRequest -Uri $next -Headers $headers -UseBasicParsing -ErrorAction Stop
                                $response = $raw.Content | ConvertFrom-Json
                                if ($raw.Headers["Link"]) {
                                        $link = $raw.Headers["Link"][0]
                                }
                                else {
                                        $link = $null
                                }

                                break
                        }
                        catch {
                                if ($attempt -ge 5) { throw $_ }
                                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                        }
                }

                if ($response -is [System.Array]) { $results += $response } else { $results += , $response }

                if ($link -and $link -match '<(?<url>[^>]+)>;\s*rel="next"') {
                        $next = $Matches['url']
                }
                else {
                        $next = $null
                }
        }
        return $results
}

function Get-OpenPullRequests {
        param([string]$owner, [string]$repo)

        $url = "$baseUrl/repos/$owner/$repo/pulls?state=open&per_page=100"
        $prs = Get-AllPaged -Url $url

        Write-Host "Found $($prs.Count) open pull requests." -ForegroundColor Yellow

        $prObjects = foreach ($pr in $prs) {
                $prNumber = $pr.number
                $title = $pr.title
                $author = if ($pr.user -and $pr.user.login) { $pr.user.login } else { $pr.user.name }
                $headSha = $pr.head.sha
                $createdAt = $pr.created_at.ToString("o")
                $updatedAt = $pr.updated_at.ToString("o")

                $createdAtPretty = $pr.created_at.ToString("MMM dd, yyyy HH:mm")
                $updatedAtPretty = $pr.updated_at.ToString("MMM dd, yyyy HH:mm")

                # reviews -> check for approvals
                $reviewsUrl = "$baseUrl/repos/$owner/$repo/pulls/$prNumber/reviews"
                $reviews = @()
                try { $reviews = Invoke-GitHubApi -Url $reviewsUrl } catch { $reviews = @() }
                $approved = $false
                # Write-Host "Processing PR #$prNumber\: '$title' by $author ..." -ForegroundColor DarkCyan
                if ($reviews) {
                        foreach ($r in $reviews) {
                                if ($r.state -eq "APPROVED") { $approved = $true; break }
                        }
                }

                # check runs
                $checkRunsUrl = "$baseUrl/repos/$owner/$repo/commits/$headSha/check-runs"
                $checkRuns = @()
                try {
                        $cr = Invoke-GitHubApi -Url $checkRunsUrl
                        if ($cr -and $cr.check_runs) { $checkRuns = $cr.check_runs }
                }
                catch { $checkRuns = @() }

                [PSCustomObject]@{
                        Number    = $prNumber
                        Title     = $title
                        Author    = $author
                        Approved  = if ($approved) { "Yes" } else { "No" }
                        CheckRuns = ($checkRuns | ForEach-Object { "{0}:{1}" -f $_.name, ($_.conclusion -or $_.status) }) -join "; "
                        Url       = $pr.html_url
                        CreatedAt = $createdAt
                        CreatedAtPretty = $createdAtPretty
                        UpdatedAt = $updatedAt
                        UpdatedAtPretty = $updatedAtPretty
                }
        }

        return $prObjects
}

function Get-BranchesInfo {
        param([string]$owner, [string]$repo)

        $url = "$baseUrl/repos/$owner/$repo/branches?per_page=100"
        $branches = Get-AllPaged -Url $url

        Write-Host "Found $($branches.Count) branches." -ForegroundColor Yellow

        $branchObjects = foreach ($b in $branches) {
                # Write-Host "Processing branch $($b.name) ..." -ForegroundColor DarkCyan

                $bName = $b.name
                $sha = $b.commit.sha

                $commitUrl = "$baseUrl/repos/$owner/$repo/commits/$sha"
                $commit = $null
                try { $commit = Invoke-GitHubApi -Url $commitUrl } catch { $commit = $null }

                if ($commit) {
                        $authorLogin = if ($commit.author -and $commit.author.login) { $commit.author.login } else { $commit.commit.author.name }
                        $dateText = $commit.commit.author.date.ToString("MMM dd, yyyy HH:mm")
                        $date = $commit.commit.author.date.ToString("o")
                        $message = $commit.commit.message
                        $htmlUrl = $commit.html_url
                }
                else {
                        $authorLogin = $null
                        $dateText = $null
                        $date = $null
                        $message = $null
                        $htmlUrl = $null
                }

                [PSCustomObject]@{
                        BranchName       = $bName
                        LastCommitSha    = $sha
                        LastCommitAuthor = $authorLogin
                        LastCommitDateText   = $dateText
                        LastCommitDate = $date
                        LastCommitMsg    = $message
                        LastCommitUrl    = $htmlUrl
                }
        }

        return $branchObjects
}

# Main
try {
        Write-Host "Querying repository $Org/$Repo ..." -ForegroundColor Cyan

        $prs = Get-OpenPullRequests -owner $Org -repo $Repo
        $branches = Get-BranchesInfo -owner $Org -repo $Repo

        if ($AsJson) {
                $out = @{
                        Repository   = "$Org/$Repo"
                        Retrieved    = (Get-Date).ToString("o")
                        PullRequests = $prs
                        Branches     = $branches
                }
                $out | ConvertTo-Json -Depth 6
                return
        }

        Write-Host ""
        Write-Host "Open Pull Requests:" -ForegroundColor Green
        if (-not $prs -or $prs.Count -eq 0) {
                Write-Host "  (none)"
        }
        else {
                $prs | Sort-Object -Property Number | Format-Table @{Label = "Number"; Expression = { $_.Number }; Width = 6 },
                @{Label = "Title"; Expression = { $_.Title }; Width = 60 },
                @{Label = "Author"; Expression = { $_.Author }; Width = 20 },
                @{Label = "Approved"; Expression = { $_.Approved }; Width = 8 },
                @{Label = "CheckRuns/Statuses"; Expression = { ($_.CheckRuns).Trim() }; Width = 60 }
                @{Label = "CreatedAt"; Expression = { $_.CreatedAtPretty }; Width = 25 },
                @{Label = "UpdatedAt"; Expression = { $_.UpdatedAtPretty }; Width = 25 }
        }

        Write-Host ""
        Write-Host "Branches:" -ForegroundColor Green
        if (-not $branches -or $branches.Count -eq 0) {
                Write-Host "  (none)"
        }
        else {
                $branches | Sort-Object -Property BranchName | Format-Table @{Label = "Branch"; Expression = { $_.BranchName }; Width = 50 },
                @{Label = "LastCommit"; Expression = { $_.LastCommitSha }; Width = 20 },
                @{Label = "Author"; Expression = { $_.LastCommitAuthor }; Width = 25 },
                @{Label = "Date (Pretty)"; Expression = { $_.LastCommitDateText }; Width = 25 },
                @{Label = "Date (ISO)"; Expression = { $_.LastCommitDate }; Width = 30 },
                @{Label = "Message"; Expression = { $_.LastCommitMsg }; Width = 80 }
        }

}
catch {
        Write-Error $_
        exit 1
}