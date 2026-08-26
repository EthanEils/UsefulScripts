[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Identity,

    [string]$OutputPath = ".\AdMembershipTrace\$Identity",

    [switch]$IncludeTokenGroups,

    [switch]$AsciiTree,

    [ValidateSet('None', 'Error', 'Warning', 'Information', 'Verbose', 'Debug', 'All')]
    [string]$LogLevel = 'None',

    [switch]$Silent
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory

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

# ============================================================
# Helpers
# ============================================================

function Convert-BytesToSid {
    param([byte[]]$Bytes)

    if (-not $Bytes) { return $null }
    return (New-Object System.Security.Principal.SecurityIdentifier($Bytes, 0)).Value
}

function Get-CleanLdapFilterValue {
    param([string]$Value)

    if ($null -eq $Value) { return $null }

    $Value = $Value -replace '\\', '\5c'
    $Value = $Value -replace '\*', '\2a'
    $Value = $Value -replace '\(', '\28'
    $Value = $Value -replace '\)', '\29'
    $Value = $Value -replace "`0", '\00'

    return $Value
}


function Get-DomainFromDn {
    param([string]$DistinguishedName)

    if (-not $DistinguishedName) { return $null }

    $matchValues = [regex]::Matches($DistinguishedName, '(?i)DC=([^,]+)')
    if ($matchValues.Count -eq 0) { return $null }

    $parts = foreach ($m in $matchValues) {
        $m.Groups[1].Value
    }

    return ($parts -join '.')
}


function Get-GroupScopeFromGroupType {
    param([int]$GroupType)

    switch ($GroupType -band 0x0000000E) {
        0x00000002 { return 'Global' }
        0x00000004 { return 'DomainLocal' }
        0x00000008 { return 'Universal' }
        default { return 'Unknown' }
    }
}

function Get-ForestDomains {
    $forest = Get-ADForest
    $domains = @()

    foreach ($domainName in $forest.Domains) {
        try {
            $dc = (Get-ADDomainController -Discover -DomainName $domainName -Writable).HostName
        }
        catch {
            $dc = (Get-ADDomainController -Discover -DomainName $domainName).HostName
        }

        $rootDse = [ADSI]"LDAP://$dc/RootDSE"

        $domains += [pscustomobject]@{
            DomainDns                  = $domainName
            Server                     = $dc
            DefaultNamingContext       = [string]$rootDse.defaultNamingContext
            ConfigurationNamingContext = [string]$rootDse.configurationNamingContext
        }
    }

    return $domains
}

function New-DirectorySearcher {
    param(
        [string]$LdapPath,
        [string]$Filter,
        [string[]]$Properties = @('*'),
        [System.DirectoryServices.SearchScope]$SearchScope = [System.DirectoryServices.SearchScope]::Subtree,
        [int]$PageSize = 1000
    )

    $entry = New-Object System.DirectoryServices.DirectoryEntry($LdapPath)
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)

    $searcher.Filter = $Filter
    $searcher.SearchScope = $SearchScope
    $searcher.PageSize = $PageSize

    foreach ($p in $Properties) {
        [void]$searcher.PropertiesToLoad.Add($p)
    }

    return $searcher
}

function Convert-SearchResultToNode {
    param(
        [System.DirectoryServices.SearchResult]$Result
    )

    $p = $Result.Properties

    $dn = if ($p['distinguishedname']) { [string]$p['distinguishedname'][0] } else { $null }
    $domain = Get-DomainFromDn -DistinguishedName $dn

    $objectClass = $null
    if ($p['objectclass'].Count -gt 0) {
        $objectClass = [string]$p['objectclass'][$p['objectclass'].Count - 1]
    }

    $groupType = if ($p['grouptype'].Count -gt 0) { [int]$p['grouptype'][0] } else { $null }
    $groupScope = if ($objectClass -eq 'group' -and $null -ne $groupType) { Get-GroupScopeFromGroupType $groupType } else { $null }

    [pscustomobject]@{
        DistinguishedName = $dn
        Name              = if ($p['name'].Count -gt 0) { [string]$p['name'][0] } else { $null }
        SamAccountName    = if ($p['samaccountname'].Count -gt 0) { [string]$p['samaccountname'][0] } else { $null }
        UserPrincipalName = if ($p['userprincipalname'].Count -gt 0) { [string]$p['userprincipalname'][0] } else { $null }
        ObjectClass       = $objectClass
        ObjectSid         = if ($p['objectsid'].Count -gt 0) { Convert-BytesToSid $p['objectsid'][0] } else { $null }
        PrimaryGroupId    = if ($p['primarygroupid'].Count -gt 0) { [int]$p['primarygroupid'][0] } else { $null }
        GroupType         = $groupType
        GroupScope        = $groupScope
        DomainDns         = $domain
        AdsPath           = $Result.Path
    }
}

function Write-AsciiTree {
    param(
        [string]$RootName,
        [hashtable]$Adjacency,
        [string]$Direction  # "Up" or "Down"
    )

    if ($Direction -eq "Up") {
        Write-Host "========== ASCII TREE (PARENTS) =========="
    }
    else {
        Write-Host "========== ASCII TREE (CHILDREN) =========="
    }

    Write-Host $RootName

    $visited = @{}

    function Walk {
        param(
            [string]$Node,
            [string]$Prefix = ""
        )

        if ($visited.ContainsKey($Node)) {
            Write-Host "$Prefix└── [LOOP] $Node"
            return
        }

        $visited[$Node] = $true

        if (-not $Adjacency.ContainsKey($Node)) {
            return
        }

        $children = $Adjacency[$Node]
        $count = $children.Count

        for ($i = 0; $i -lt $count; $i++) {
            $child = $children[$i]

            $isLast = ($i -eq $count - 1)

            $connector = if ($isLast) { "└──" } else { "├──" }
            Write-Host "$Prefix$connector $child"

            $newPrefix = if ($isLast) { "$Prefix    " } else { "$Prefix│   " }

            Walk -Node $child -Prefix $newPrefix
        }
    }

    Walk -Node $RootName
}

# ============================================================
# Forest discovery
# ============================================================

$script:ForestDomains = Get-ForestDomains

Write-Log -Level 'Information' -Message "Discovered forest domains:"
foreach ($d in $script:ForestDomains) {
    Write-Log -Level 'Information' -Message " - $($d.DomainDns) (DC: $($d.Server))"
}

# Write-Host "Global Catalog: $($script:GlobalCatalog)"

# ============================================================
# Object resolution
# ============================================================


function Resolve-Principal {
    param([string]$Identity)

    $escaped = Get-CleanLdapFilterValue $Identity
    $allMatches = New-Object System.Collections.Generic.List[object]

    foreach ($domain in $script:ForestDomains) {
        $searcher = New-DirectorySearcher `
            -LdapPath "LDAP://$($domain.Server)/$($domain.DefaultNamingContext)" `
            -Filter "(|(&(objectCategory=person)(objectClass=user)(sAMAccountName=$escaped))(&(objectCategory=person)(objectClass=user)(userPrincipalName=$escaped))(&(objectCategory=person)(objectClass=user)(distinguishedName=$escaped))(&(objectCategory=person)(objectClass=user)(cn=$escaped))(&(objectCategory=person)(objectClass=user)(name=$escaped))(&(objectCategory=group)(sAMAccountName=$escaped))(&(objectCategory=group)(distinguishedName=$escaped))(&(objectCategory=group)(cn=$escaped))(&(objectCategory=group)(name=$escaped))(&(objectCategory=computer)(sAMAccountName=$escaped))(&(objectCategory=computer)(distinguishedName=$escaped))(&(objectCategory=computer)(cn=$escaped))(&(objectCategory=computer)(name=$escaped)))" `
            -Properties @(
            'distinguishedName',
            'name',
            'sAMAccountName',
            'userPrincipalName',
            'objectClass',
            'objectSid',
            'primaryGroupID',
            'groupType'
        )

        $results = $searcher.FindAll()

        foreach ($result in $results) {
            $allMatches.Add((Convert-SearchResultToNode $result))
        }
    }

    if ($allMatches.Count -eq 0) {
        throw "Could not resolve identity '$Identity' anywhere in the forest."
    }

    # Deduplicate by DN
    $deduped = New-Object System.Collections.Generic.List[object]
    $allMatches |
    Group-Object DistinguishedName |
    ForEach-Object { $deduped.Add($_.Group[0]) }

    if ($deduped.Count -gt 1) {
        $summary = $deduped | ForEach-Object {
            "$($_.ObjectClass): $($_.SamAccountName) [$($_.DistinguishedName)]"
        }

        throw "Identity '$Identity' matched multiple objects:`n$($summary -join "`n")"
    }

    return $deduped[0]
}

function Get-DirectoryObjectByDn {
    param([string]$DistinguishedName)

    $domain = Get-DomainFromDn $DistinguishedName
    if (-not $domain) { return $null }

    $domainInfo = $script:ForestDomains | Where-Object { $_.DomainDns -ieq $domain } | Select-Object -First 1
    if (-not $domainInfo) { return $null }

    $ldapPath = "LDAP://$($domainInfo.Server)/$DistinguishedName"

    $searcher = New-DirectorySearcher `
        -LdapPath $ldapPath `
        -Filter "(objectClass=*)" `
        -SearchScope Base `
        -Properties @(
        'distinguishedName',
        'name',
        'sAMAccountName',
        'userPrincipalName',
        'objectClass',
        'objectSid',
        'primaryGroupID',
        'groupType'
    )

    $res = $searcher.FindOne()
    if (-not $res) { return $null }

    return Convert-SearchResultToNode $res
}

function Get-PrimaryGroupNode {
    param([pscustomobject]$Node)

    if (-not $Node.ObjectSid -or -not $Node.PrimaryGroupId) {
        return $null
    }

    $sidPrefix = $Node.ObjectSid -replace '-\d+$', ''
    $primaryGroupSid = "$sidPrefix-$($Node.PrimaryGroupId)"

    foreach ($domain in $script:ForestDomains) {
        $escapedSid = Get-CleanLdapFilterValue $primaryGroupSid

        $searcher = New-DirectorySearcher `
            -LdapPath "LDAP://$($domain.Server)/$($domain.DefaultNamingContext)" `
            -Filter "(&(objectCategory=group)(objectSid=$escapedSid))" `
            -Properties @(
            'distinguishedName',
            'name',
            'sAMAccountName',
            'userPrincipalName',
            'objectClass',
            'objectSid',
            'primaryGroupID',
            'groupType'
        )

        $res = $searcher.FindOne()
        if ($res) {
            return Convert-SearchResultToNode $res
        }
    }

    return $null
}

# ============================================================
# Upward traversal
# ============================================================

function Get-DirectParentGroups {
    param([string]$MemberDn)

    $escapedDn = Get-CleanLdapFilterValue $MemberDn
    $parents = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($domain in $script:ForestDomains) {
        $searcher = New-DirectorySearcher `
            -LdapPath "LDAP://$($domain.Server)/$($domain.DefaultNamingContext)" `
            -Filter "(&(objectCategory=group)(member=$escapedDn))" `
            -Properties @(
            'distinguishedName',
            'name',
            'sAMAccountName',
            'userPrincipalName',
            'objectClass',
            'objectSid',
            'primaryGroupID',
            'groupType'
        )

        $results = $searcher.FindAll()

        foreach ($r in $results) {
            $obj = Convert-SearchResultToNode $r
            if (-not $seen.ContainsKey($obj.DistinguishedName)) {
                $seen[$obj.DistinguishedName] = $true
                $parents.Add($obj)
            }
        }
    }

    return $parents.ToArray()
}

# ============================================================
# Downward traversal
# ============================================================

function Get-GroupMemberDns {
    param([string]$GroupDn)

    $domain = Get-DomainFromDn $GroupDn
    if (-not $domain) { return @() }

    $domainInfo = $script:ForestDomains | Where-Object { $_.DomainDns -ieq $domain } | Select-Object -First 1
    if (-not $domainInfo) { return @() }

    $ldapPath = "LDAP://$($domainInfo.Server)/$GroupDn"
    $memberDns = New-Object System.Collections.Generic.List[string]

    $rangeStart = 0
    $step = 1500

    while ($true) {
        $entry = New-Object System.DirectoryServices.DirectoryEntry($ldapPath)
        $rangeAttr = "member;range=$rangeStart-$($rangeStart + $step - 1)"

        try {
            $entry.RefreshCache(@($rangeAttr))
        }
        catch {
            # Some groups with small member counts may not expose range property.
        }

        $propNames = @($entry.Properties.PropertyNames)
        $rangeProp = $propNames | Where-Object { $_ -like 'member;range=*' } | Select-Object -First 1

        if ($rangeProp) {
            foreach ($m in $entry.Properties[$rangeProp]) {
                $memberDns.Add([string]$m)
            }

            if ($rangeProp -match 'member;range=\d+-\*$') {
                break
            }

            $rangeStart += $step
            continue
        }

        # Fallback for smaller groups
        if ($entry.Properties['member'].Count -gt 0) {
            foreach ($m in $entry.Properties['member']) {
                $memberDns.Add([string]$m
                )
            }
        }

        break
    }

    return $memberDns.ToArray()
}

# ============================================================
# tokenGroups helper
# ============================================================

function Get-TokenGroupNodes {
    param([pscustomobject]$Node)

    $domain = Get-DomainFromDn $Node.DistinguishedName
    if (-not $domain) { return @() }

    $domainInfo = $script:ForestDomains | Where-Object { $_.DomainDns -ieq $domain } | Select-Object -First 1
    if (-not $domainInfo) { return @() }

    $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$($domainInfo.Server)/$($Node.DistinguishedName)")
    $entry.RefreshCache(@('tokenGroups'))

    $nodes = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($raw in $entry.Properties['tokenGroups']) {
        $sid = Convert-BytesToSid $raw
        if (-not $sid) { continue }

        foreach ($d in $script:ForestDomains) {
            $escapedSid = Get-CleanLdapFilterValue $sid

            $searcher = New-DirectorySearcher `
                -LdapPath "LDAP://$($d.Server)/$($d.DefaultNamingContext)" `
                -Filter "(&(objectCategory=group)(objectSid=$escapedSid))" `
                -Properties @(
                'distinguishedName',
                'name',
                'sAMAccountName',
                'userPrincipalName',
                'objectClass',
                'objectSid',
                'primaryGroupID',
                'groupType'
            )

            $res = $searcher.FindOne()

            if ($res) {
                $group = Convert-SearchResultToNode $res
                if (-not $seen.ContainsKey($group.DistinguishedName)) {
                    $seen[$group.DistinguishedName] = $true
                    $nodes.Add($group)
                }
                break
            }
        }
    }

    return $nodes.ToArray()
}

# ============================================================
# Tree structures
# ============================================================

$script:ParentEdges = New-Object System.Collections.Generic.List[object]
$script:ChildEdges = New-Object System.Collections.Generic.List[object]
$script:ParentPaths = New-Object System.Collections.Generic.List[string]
$script:ChildPaths = New-Object System.Collections.Generic.List[string]
$script:VisitedParents = @{}
$script:VisitedChildren = @{}

function Trace-Parents {
    param(
        [pscustomobject]$Node,
        [string]$CurrentPath = ""
    )

    if (-not $Node) { return }

    if (-not $script:VisitedParents) {
        $script:VisitedParents = @{}
    }

    if ($script:VisitedParents.ContainsKey($Node.DistinguishedName)) {
        return
    }

    $script:VisitedParents[$Node.DistinguishedName] = $true


    Write-Log -Level 'Information' -Message "Tracing parents of $($Node.SamAccountName) [$($Node.DistinguishedName)]"
    
    # Primary group
    $primary = Get-PrimaryGroupNode -Node $Node
    if ($primary) {
        $path = if ($CurrentPath) {
            "$CurrentPath -> [PrimaryGroup] $($primary.SamAccountName)"
        }
        else {
            "$($Node.SamAccountName) -> [PrimaryGroup] $($primary.SamAccountName)"
        }

        $script:ParentPaths.Add($path)

        $script:ParentEdges.Add([pscustomobject]@{
                Direction    = 'Up'
                Relationship = 'PrimaryGroup'
                ParentDn     = $primary.DistinguishedName
                ParentName   = $primary.Name
                ParentSam    = $primary.SamAccountName
                ParentClass  = $primary.ObjectClass
                ParentDomain = $primary.DomainDns
                ParentScope  = $primary.GroupScope
                ChildDn      = $Node.DistinguishedName
                ChildName    = $Node.Name
                ChildSam     = $Node.SamAccountName
                ChildClass   = $Node.ObjectClass
                ChildDomain  = $Node.DomainDns
                Path         = $path
            })
    }

    Write-Verbose "Finding direct parent groups of $($Node.SamAccountName)..."
    # Direct parent groups across all domains
    $parents = @(Get-DirectParentGroups -MemberDn $Node.DistinguishedName)
    Write-Verbose "Found $($parents.Count) direct parent groups."


    for ($i = 0; $i -lt $parents.Count; $i++) {
        $parent = $parents[$i]

        $percent = 0
        if ($parents.Count -gt 0) { $percent = [int](($i + 1) / $parents.Count * 100) }
        Write-Progress -Activity "Tracing parent groups" -Status "Processing $($parent.SamAccountName) ($($i+1)/$($parents.Count))" -PercentComplete $percent

        $path = if ($CurrentPath) {
            "$CurrentPath -> $($parent.SamAccountName)"
        }
        else {
            "$($Node.SamAccountName) -> $($parent.SamAccountName)"
        }

        $script:ParentPaths.Add($path)

        $script:ParentEdges.Add([pscustomobject]@{
                Direction    = 'Up'
                Relationship = 'DirectMember'
                ParentDn     = $parent.DistinguishedName
                ParentName   = $parent.Name
                ParentSam    = $parent.SamAccountName
                ParentClass  = $parent.ObjectClass
                ParentDomain = $parent.DomainDns
                ParentScope  = $parent.GroupScope
                ChildDn      = $Node.DistinguishedName
                ChildName    = $Node.Name
                ChildSam     = $Node.SamAccountName
                ChildClass   = $Node.ObjectClass
                ChildDomain  = $Node.DomainDns
                Path         = $path
            })

        Write-Verbose "Recursively tracing parents of $($parent.SamAccountName)..."

        Trace-Parents -Node $parent -CurrentPath $path
    }
    # clear progress for parents when done
    Write-Progress -Activity "Tracing parent groups" -Completed
}

function Trace-Children {
    param(
        [pscustomobject]$Node,
        [string]$CurrentPath = ""
    )

    if (-not $Node) { return }
    if ($Node.ObjectClass -ne 'group') { return }

    if (-not $script:VisitedChildren) {
        $script:VisitedChildren = @{}
    }

    if ($script:VisitedChildren.ContainsKey($Node.DistinguishedName)) {
        return
    }

    $script:VisitedChildren[$Node.DistinguishedName] = $true

    Write-Log -Level 'Information' -Message "Tracing children of $($Node.SamAccountName) [$($Node.DistinguishedName)]"

    $memberDns = @(Get-GroupMemberDns -GroupDn $Node.DistinguishedName)

    Write-Verbose "Found $($memberDns.Count) direct members of $($Node.SamAccountName)."

    for ($i = 0; $i -lt $memberDns.Count; $i++) {
        $memberDn = $memberDns[$i]

        $percent = 0
        if ($memberDns.Count -gt 0) { $percent = [int](($i + 1) / $memberDns.Count * 100) }
        Write-Progress -Activity "Tracing child members" -Status "Processing $($i+1) of $($memberDns.Count)" -PercentComplete $percent

        Write-Verbose "Processing member $memberDn..."
        $child = Get-DirectoryObjectByDn -DistinguishedName $memberDn
        if (-not $child) { continue }

        $path = if ($CurrentPath) {
            "$CurrentPath -> $($child.SamAccountName)"
        }
        else {
            "$($Node.SamAccountName) -> $($child.SamAccountName)"
        }

        $script:ChildPaths.Add($path)

        $script:ChildEdges.Add([pscustomobject]@{
                Direction    = 'Down'
                Relationship = 'DirectMember'
                ParentDn     = $Node.DistinguishedName
                ParentName   = $Node.Name
                ParentSam    = $Node.SamAccountName
                ParentClass  = $Node.ObjectClass
                ParentDomain = $Node.DomainDns
                ParentScope  = $Node.GroupScope
                ChildDn      = $child.DistinguishedName
                ChildName    = $child.Name
                ChildSam     = $child.SamAccountName
                ChildClass   = $child.ObjectClass
                ChildDomain  = $child.DomainDns
                Path         = $path
            })

        if ($child.ObjectClass -eq 'group') {
            Write-Verbose "Recursively tracing children of $($child.SamAccountName)..."
            Trace-Children -Node $child -CurrentPath $path
        }
    }
    Write-Progress -Activity "Tracing child members" -Completed
}

# ============================================================
# Run
# ============================================================


$root = Resolve-Principal -Identity $Identity

Write-Host ""
Write-Host "Resolved root object:" -NoNewline
$root | Format-List

Write-Progress -Activity "Tracing parent groups" -Status "Tracing parents of $($root.SamAccountName)..."

Trace-Parents -Node $root

Write-Progress -Activity "Tracing parent groups" -Status "Completed" -Completed

if ($root.ObjectClass -eq 'group') {
    Write-Host ""

    Write-Progress -Activity "Tracing child members" -Status "Tracing children of $($root.SamAccountName)..."

    Trace-Children -Node $root

    Write-Progress -Activity "Tracing child members" -Status "Completed" -Completed
}

$effectiveGroups = @()
if ($IncludeTokenGroups.IsPresent -and $root.ObjectClass -in @('user', 'computer')) {
    try {
        $effectiveGroups = Get-TokenGroupNodes -Node $root
    }
    catch {
        Write-Warning "tokenGroups lookup failed: $($_.Exception.Message)"
    }
}

# ============================================================
# Output
# ============================================================


if ($AsciiTree.IsPresent) {
    $parentMap = @{}

    foreach ($edge in $script:ParentEdges) {
        $child = $edge.ChildSam
        $parent = $edge.ParentSam

        if (-not $parentMap.ContainsKey($child)) {
            $parentMap[$child] = New-Object System.Collections.Generic.List[string]
        }

        if ($parent) {
            $parentMap[$child].Add($parent)
        }
    }

    $childMap = @{}

    foreach ($edge in $script:ChildEdges) {
        $parent = $edge.ParentSam
        $child = $edge.ChildSam

        if (-not $childMap.ContainsKey($parent)) {
            $childMap[$parent] = New-Object System.Collections.Generic.List[string]
        }

        if ($child) {
            $childMap[$parent].Add($child)
        }
    }

    Write-AsciiTree -RootName $root.SamAccountName -Adjacency $parentMap -Direction "Up"

    if ($root.ObjectClass -eq 'group') {
        Write-AsciiTree -RootName $root.SamAccountName -Adjacency $childMap -Direction "Down"
    }
}
else {


    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath | Out-Null
    }

    $summary = [pscustomobject]@{
        RootInput           = $Identity
        ResolvedDn          = $root.DistinguishedName
        ResolvedName        = $root.Name
        ResolvedSam         = $root.SamAccountName
        ResolvedClass       = $root.ObjectClass
        ResolvedDomain      = $root.DomainDns
        ParentEdgeCount     = $script:ParentEdges.Count
        ChildEdgeCount      = $script:ChildEdges.Count
        IncludeTokenGroups  = [bool]$IncludeTokenGroups
        EffectiveGroupCount = $effectiveGroups.Count
        GeneratedAt         = (Get-Date).ToString("s")
    }

    $summary | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputPath "Summary.json") -Encoding utf8
    $script:ParentEdges | Export-Csv -Path (Join-Path $OutputPath "ParentTree.csv") -NoTypeInformation -Encoding UTF8
    $script:ChildEdges  | Export-Csv -Path (Join-Path $OutputPath "ChildTree.csv") -NoTypeInformation -Encoding UTF8

    $script:ParentPaths | Sort-Object -Unique | Out-File -FilePath (Join-Path $OutputPath "ParentPaths.txt") -Encoding utf8
    $script:ChildPaths  | Sort-Object -Unique | Out-File -FilePath (Join-Path $OutputPath "ChildPaths.txt") -Encoding utf8

    $combined = @()
    $combined += $script:ParentEdges
    $combined += $script:ChildEdges
    $combined | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $OutputPath "FullTrace.json") -Encoding utf8

    if ($effectiveGroups.Count -gt 0) {
        $effectiveGroups |
        Select-Object Name, SamAccountName, DistinguishedName, DomainDns, GroupScope, ObjectSid |
        Export-Csv -Path (Join-Path $OutputPath "EffectiveSecurityGroups.csv") -NoTypeInformation -Encoding UTF8
    }

    Write-Host ""
    Write-Host "Trace complete."
    Write-Host "Summary:         $(Join-Path $OutputPath 'Summary.json')"
    Write-Host "Parent tree:     $(Join-Path $OutputPath 'ParentTree.csv')"
    Write-Host "Child tree:      $(Join-Path $OutputPath 'ChildTree.csv')"
    Write-Host "Parent paths:    $(Join-Path $OutputPath 'ParentPaths.txt')"
    Write-Host "Child paths:     $(Join-Path $OutputPath 'ChildPaths.txt')"
    Write-Host "Combined trace:  $(Join-Path $OutputPath 'FullTrace.json')"

    if ($effectiveGroups.Count -gt 0) {
        Write-Host "Effective groups: $(Join-Path $OutputPath 'EffectiveSecurityGroups.csv')"
    }
}