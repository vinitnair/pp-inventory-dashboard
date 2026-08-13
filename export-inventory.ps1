<#
    Power Platform tenant inventory -> dashboard.html

    USAGE
      Install-Module Az.Accounts -Scope CurrentUser      # only module needed
      Connect-AzAccount -Tenant <tenantId>               # add -UseDeviceAuthentication if MFA blocks the popup
      .\export-inventory.ps1                             # prompts for a passphrase, writes dashboard.html

      .\export-inventory.ps1 -NoPassword                 # deliberately unprotected, tenant data in the clear
      .\export-inventory.ps1 -Ephemeral                  # temp file, opens it, then shreds it
      .\export-inventory.ps1 -Demo                       # render synthetic data, no tenant or sign-in needed

    A real report carries tenant IDs, environment GUIDs, resource names and maker
    names, so it is encrypted by default and weak passphrases are refused. See the
    README for why a sensitivity label beats a passphrase inside your own tenant.

    REQUIRES
      An Entra role: Global admin, Power Platform admin, Dynamics 365 admin, Global
      reader, or AI admin/reader. Power Platform RBAC roles do NOT work here.
      Keep dashboard.template.html in the same folder.

    WHY REST INSTEAD OF `az graph query`
      PowerPlatformResources is a TENANT-scoped Resource Graph table. az CLI always
      scopes to subscriptions and has no tenant flag, so it returns AccessDenied.
      Omitting both `subscriptions` and `managementGroups` below selects tenant scope.
#>

[CmdletBinding()]
param(
    [switch]$Demo,
    [int]$DemoEnvironments = 4,
    [switch]$Deep,
    [switch]$NoMakerNames,
    [securestring]$Password,
    [switch]$NoPassword,
    [switch]$Ephemeral,
    [string]$SensitivityLabel,
    [string]$UploadTo,
    [string]$ShareWithGroup,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if ($Ephemeral) {
    if ($OutFile) { throw "-Ephemeral writes to a temporary path; drop -OutFile." }
    # Deliberately outside the repo and outside any synced folder.
    $OutFile = Join-Path ([IO.Path]::GetTempPath()) ("pp-inventory-{0}.html" -f [guid]::NewGuid().ToString('n').Substring(0, 8))
}
if (-not $OutFile) { $OutFile = Join-Path $root 'dashboard.html' }

# The report is attackable offline by anyone holding it, so length is what counts.
# Composition rules are deliberately not enforced; NIST SP 800-63B advises against them.
function Test-Passphrase {
    param([string]$Value)

    $weak = @(
        'password', 'passphrase', 'welcome', 'letmein', 'qwerty', 'admin', 'secret',
        'contoso', 'microsoft', 'powerplatform', 'dashboard', 'inventory', 'changeme'
    )
    $issues = @()
    $long = $Value.Length -ge 20

    if ($Value.Length -lt 12) { $issues += "must be at least 12 characters (got $($Value.Length))" }
    if (($Value.ToCharArray() | Sort-Object -Unique).Count -lt 5) { $issues += 'must use at least 5 different characters' }
    if (-not $long) {
        foreach ($w in $weak) {
            if ($Value -match [regex]::Escape($w)) { $issues += "must not contain the common word '$w'"; break }
        }
    }
    if ($Value -match '^(.)\1+$') { $issues += 'must not be a single repeated character' }
    if ($Value -match '(?i)^(012|123|234|345|456|567|678|789|abc|qwe|asd)') { $issues += 'must not start with a keyboard or digit run' }

    # Rough entropy: a long phrase passes on length alone, a short one needs variety.
    $classes = 0
    if ($Value -cmatch '[a-z]') { $classes += 26 }
    if ($Value -cmatch '[A-Z]') { $classes += 26 }
    if ($Value -match '\d') { $classes += 10 }
    if ($Value -match '[^a-zA-Z0-9]') { $classes += 33 }
    $bits = if ($classes) { [math]::Floor($Value.Length * [math]::Log($classes, 2)) } else { 0 }
    if ($bits -lt 60 -and -not $long) {
        $issues += "too predictable (about $bits bits; needs 60+, or 20+ characters)"
    }

    [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = $issues; Bits = $bits }
}

function Read-StrongPassphrase {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $first = Read-Host 'Passphrase' -AsSecureString
        if (-not $first -or $first.Length -eq 0) {
            throw "No passphrase entered. Re-run with -NoPassword if you really want an unprotected report."
        }
        $plain = [System.Net.NetworkCredential]::new('', $first).Password
        $check = Test-Passphrase $plain

        if (-not $check.Ok) {
            Write-Host "  Rejected. The passphrase $($check.Issues -join '; ')." -ForegroundColor Red
            continue
        }

        # A typo here would make the report permanently unopenable.
        $again = Read-Host 'Confirm passphrase' -AsSecureString
        if ($plain -cne [System.Net.NetworkCredential]::new('', $again).Password) {
            Write-Host "  They do not match. Try again." -ForegroundColor Red
            continue
        }

        Write-Host "  Accepted (about $($check.Bits) bits of entropy)." -ForegroundColor DarkGray
        return $first
    }
    throw "Too many failed attempts. Use a longer passphrase, or -NoPassword for an unprotected report."
}

# Real tenant data is encrypted unless the caller opts out in so many words.
if (-not $Password -and -not $NoPassword -and -not $Demo) {
    Write-Host "This report will contain tenant identifiers, resource names and maker names." -ForegroundColor Yellow
    Write-Host "Choose a passphrase of 12+ characters, or re-run with -NoPassword to skip." -ForegroundColor Yellow
    $Password = Read-StrongPassphrase
}
elseif ($Password) {
    $check = Test-Passphrase ([System.Net.NetworkCredential]::new('', $Password).Password)
    if (-not $check.Ok) {
        throw "Passphrase rejected: it $($check.Issues -join '; '). This report can be attacked offline by anyone who holds it."
    }
}

$ctx = $null
if (-not $Demo) {
    $ctx = Get-AzContext
    if (-not $ctx) { throw "Not connected. Run: Connect-AzAccount -Tenant <tenantId>" }
    Write-Host "Querying tenant $($ctx.Tenant.Id) as $($ctx.Account.Id)..." -ForegroundColor Cyan
}
else {
    Write-Host "Demo mode: rendering synthetic data, no tenant contacted." -ForegroundColor Cyan
}

# Search-AzGraph intermittently swallows ARG throttling responses and hands back a
# single all-null row instead of erroring, so go straight at REST and check the status.
# ARG caps every response at 1000 records, so page with $skipToken or large tenants
# silently truncate.
function Invoke-Arg {
    param([string]$Query, [int]$MaxAttempts = 5)

    $uri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01'
    $all = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    $total = $null

    do {
        $options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
        if ($skipToken) { $options['$skipToken'] = $skipToken }
        $payload = @{ query = $Query; options = $options } | ConvertTo-Json -Depth 5

        $page = $null
        for ($i = 1; $i -le $MaxAttempts; $i++) {
            $resp = Invoke-AzRestMethod -Method POST -Uri $uri -Payload $payload
            if ($resp.StatusCode -eq 200) { $page = $resp.Content | ConvertFrom-Json; break }
            if ($resp.StatusCode -eq 429) {
                $wait = 5 * $i
                Write-Host "  throttled by ARG, retrying in ${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            throw "ARG returned $($resp.StatusCode): $($resp.Content)"
        }
        if (-not $page) { throw "ARG still throttling after $MaxAttempts attempts." }

        if ($null -ne $page.data) { $all.AddRange([object[]]@($page.data)) }
        $total = $page.totalRecords
        $skipToken = $page.'$skipToken'
        if ($skipToken) { Write-Host "  fetched $($all.Count) of $total..." -ForegroundColor DarkGray }
    } while ($skipToken)

    if ($null -ne $total -and $all.Count -lt $total) {
        Write-Warning "ARG reported $total records but returned $($all.Count). Results are truncated."
    }
    return $all.ToArray()
}

# ---- admin APIs (-Deep) ----
# Everything below Resource Graph is best effort. Endpoint availability varies by cloud,
# tenant and licence, and the Azure PowerShell client is not consented for every audience,
# so each probe fails soft and records why rather than taking the whole report down.
$script:tokens = @{}
function Get-ServiceToken {
    param([string]$Resource)
    if ($script:tokens.ContainsKey($Resource)) { return $script:tokens[$Resource] }
    $value = $null
    try {
        $t = Get-AzAccessToken -ResourceUrl $Resource -AsSecureString -ErrorAction Stop
        $value = [System.Net.NetworkCredential]::new('', $t.Token).Password
    }
    catch {
        Write-Warning "No access token for $Resource. $($_.Exception.Message)"
    }
    $script:tokens[$Resource] = $value
    return $value
}

function Invoke-AdminApi {
    param(
        [string[]]$Uri,          # candidates, tried in order until one answers
        [string]$Resource,
        [string]$Method = 'GET',
        $Body,
        [string]$Label
    )

    $token = Get-ServiceToken $Resource
    if (-not $token) { $script:deepSources[$Label] = 'no token'; return @() }
    $headers = @{ Authorization = "Bearer $token" }
    $lastError = 'no endpoint answered'

    foreach ($candidate in $Uri) {
        $items = [System.Collections.Generic.List[object]]::new()
        $next = $candidate
        $failed = $false

        while ($next) {
            $req = @{ Method = $Method; Uri = $next; Headers = $headers; ErrorAction = 'Stop' }
            if ($Body) { $req.Body = ($Body | ConvertTo-Json -Depth 6); $req.ContentType = 'application/json' }

            $page = $null
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try { $page = Invoke-RestMethod @req; break }
                catch {
                    $code = $_.Exception.Response.StatusCode.value__
                    if ($code -eq 429 -and $attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt); continue }
                    $lastError = if ($code) { "HTTP $code" } else { $_.Exception.Message }
                    $failed = $true
                    break
                }
            }
            if ($failed -or $null -eq $page) { break }

            if ($null -ne $page.value) { $items.AddRange([object[]]@($page.value)) } else { $items.Add($page) }
            $next = if ($page.nextLink) { $page.nextLink } elseif ($page.'@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
            if ($Method -ne 'GET') { break }
        }

        if (-not $failed) {
            $script:deepSources[$Label] = "ok ($($items.Count))"
            return $items.ToArray()
        }
    }

    Write-Warning "$Label unavailable: $lastError"
    $script:deepSources[$Label] = $lastError
    return @()
}

$resourceQuery = @'
PowerPlatformResources
| where type != 'microsoft.powerplatformconnector/connectors'
| extend p = parse_json(properties)
| project name, type, location,
    displayName      = tostring(p.displayName),
    environmentId    = tostring(p.environmentId),
    environmentType  = tostring(p.environmentType),
    isManaged        = tostring(p.isManaged),
    createdBy        = tostring(p.createdBy),
    createdAt        = tostring(p.createdAt),
    modifiedAt       = tostring(p.lastModifiedAt),
    ownerId          = tostring(p.ownerId),
    editedBy         = tostring(p.lastModifiedBy),
    envGroupId       = tostring(p.environmentGroupId),
    status           = tostring(p.status),
    isQuarantined    = tostring(p.isQuarantined),
    subType          = tostring(p.subType),
    flowTriggerType  = tostring(p.flowTriggerType),
    triggerConnId    = tostring(p.trigger.connectorId),
    triggerName      = tostring(p.trigger.connectorDisplayName),
    triggerOpId      = tostring(p.trigger.operationId),
    triggerOp        = tostring(p.trigger.operationDisplayName),
    connectors       = p.powerPlatformConnectors,
    operations       = p.powerPlatformConnectors
| order by name asc
'@

if ($Demo) {
    $rows = & (Join-Path $root 'demo-data.ps1') -Environments $DemoEnvironments
    $catalog = & (Join-Path $root 'demo-data.ps1') -Catalog
    $catalogCount = 1400
}
else {
    $rows = Invoke-Arg -Query $resourceQuery
    if ($rows.Count -lt 1) { throw "No resources returned." }

    # Tier/publisher live on the connector catalog records, not on the usage array.
    $catalog = Invoke-Arg -Query @'
PowerPlatformResources
| where type == 'microsoft.powerplatformconnector/connectors'
| extend p = parse_json(properties)
| project connectorId = tostring(p.connectorId),
    displayName  = tostring(p.displayName),
    tier         = tostring(p.tier),
    publisher    = tostring(p.publisher),
    releaseTag   = tostring(p.releaseTag),
    isDeprecated = tostring(p.isDeprecated)
| order by connectorId asc
'@
    $catalogCount = $catalog.Count
}

# Friendly labels for the raw ARG type strings.
$typeLabels = @{
    'microsoft.powerplatform/environments'      = 'Environment'
    'microsoft.powerplatform/environmentgroups' = 'Environment group'
    'microsoft.powerapps/canvasapps'            = 'Canvas app'
    'microsoft.powerapps/modeldrivenapps'       = 'Model-driven app'
    'microsoft.powerapps/codeapps'              = 'Code app'
    'microsoft.powerapps/apps'                  = 'App Builder app'
    'microsoft.powerautomate/cloudflows'        = 'Cloud flow'
    'microsoft.powerautomate/agentflows'        = 'Agent flow'
    'microsoft.powerautomate/m365agentflows'    = 'Workflow agent flow'
    'microsoft.copilotstudio/agents'            = 'Agent'
}

$envLookup = @{}
foreach ($r in $rows | Where-Object type -eq 'microsoft.powerplatform/environments') {
    $envLookup[$r.name] = $r.displayName
}

$resources = foreach ($r in $rows) {
    # Connector arrays repeat one entry per action, so collapse to distinct IDs.
    $ids = @()
    $ops = @()
    if ($r.connectors) {
        $ids = @($r.connectors | ForEach-Object { $_.connectorId } | Where-Object { $_ } | Sort-Object -Unique)
        $ops = @($r.connectors | ForEach-Object { $c = $_; $_.operations | ForEach-Object { if ($_.operationId) { "$($c.connectorId)|$($_.operationId)" } } } | Sort-Object -Unique)
    }

    $envId = if ($r.type -eq 'microsoft.powerplatform/environments') { $r.name } else { $r.environmentId }

    [pscustomobject]@{
        id          = $r.name
        type        = $r.type
        typeLabel   = if ($typeLabels.ContainsKey($r.type)) { $typeLabels[$r.type] } else { $r.type }
        name        = if ($r.displayName) { $r.displayName } else { $r.name }
        location    = $r.location
        envId       = $envId
        envName     = if ($envId -and $envLookup.ContainsKey($envId)) { $envLookup[$envId] } else { $envId }
        envType     = $r.environmentType
        envGroupId  = $r.envGroupId
        isManaged   = $r.isManaged -eq 'true'
        subType     = $r.subType
        createdAt   = $r.createdAt
        modifiedAt  = $r.modifiedAt
        createdBy   = $r.createdBy
        editedBy    = $r.editedBy
        ownerId     = $r.ownerId
        quarantined = $r.isQuarantined -eq 'true'
        status      = $r.status
        triggerType = $r.flowTriggerType
        triggerConnId = $r.triggerConnId
        triggerName = $r.triggerName
        triggerOpId = $r.triggerOpId
        triggerOp   = $r.triggerOp
        connectors  = $ids
        operations  = $ops
    }
}
$resources = @($resources)

function Group-Count($items, [string]$prop) {
    @($items | Group-Object -Property $prop | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{ key = if ($_.Name) { $_.Name } else { '(none)' }; count = $_.Count }
        })
}

# Environments and environment groups are containers, not things a maker builds, so they
# stay out of ownership, staleness, connector and archive analysis.
$containerTypes = @('microsoft.powerplatform/environments', 'microsoft.powerplatform/environmentgroups')
$nonEnv = @($resources | Where-Object { $containerTypes -notcontains $_.type })

# Counted here rather than in the browser; doing it client side is O(envs x resources).
$countByEnvId = @{}
foreach ($r in $nonEnv) { if ($r.envId) { $countByEnvId[$r.envId] = 1 + [int]$countByEnvId[$r.envId] } }

$environments = @(
    $resources | Where-Object type -eq 'microsoft.powerplatform/environments' | ForEach-Object {
        $_ | Add-Member -NotePropertyName resourceCount -NotePropertyValue ([int]$countByEnvId[$_.id]) -PassThru
    } | Sort-Object resourceCount -Descending
)

# ---- maker names: ARG only stores object IDs, so resolve them like the CoE kit does ----
$makerNames = @{}
$makerInfo = @{}
$makerIds = @($nonEnv | ForEach-Object { $_.createdBy; $_.ownerId } | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Sort-Object -Unique)
$graphChecked = $false

if ($Demo) {
    $makerInfo = & (Join-Path $root 'demo-data.ps1') -MakerNames
    foreach ($k in $makerInfo.Keys) { $makerNames[$k] = $makerInfo[$k].name }
    $graphChecked = $true
}
elseif ($makerIds.Count -and -not $NoMakerNames) {
    try {
        $tok = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -AsSecureString -ErrorAction Stop
        $plain = [System.Net.NetworkCredential]::new('', $tok.Token).Password
        $headers = @{ Authorization = "Bearer $plain"; 'Content-Type' = 'application/json' }
        $sel = 'id,displayName,department,city,country,jobTitle,accountEnabled'

        for ($i = 0; $i -lt $makerIds.Count; $i += 900) {
            $batch = $makerIds[$i..([Math]::Min($i + 899, $makerIds.Count - 1))]
            $body = @{ ids = @($batch); types = @('user', 'servicePrincipal') } | ConvertTo-Json
            $res = Invoke-RestMethod -Method POST -Headers $headers -Body $body `
                -Uri "https://graph.microsoft.com/v1.0/directoryObjects/getByIds?`$select=$sel"
            foreach ($o in $res.value) {
                $makerNames[$o.id] = $o.displayName
                $makerInfo[$o.id] = @{
                    name       = $o.displayName
                    department = $o.department
                    country    = $o.country
                    city       = $o.city
                    enabled    = ($o.accountEnabled -ne $false)
                }
            }
        }
        $graphChecked = $true
        Write-Host "  resolved $($makerNames.Count) of $($makerIds.Count) principals via Microsoft Graph" -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Could not resolve maker names via Graph ($($_.Exception.Message)). Showing object IDs instead."
    }
}

$makerLabel = { param($id) if ($makerNames.ContainsKey($id)) { $makerNames[$id] } elseif ($id) { $id } else { '(unknown)' } }

# ---- connector catalog lookup ----
$tierById = @{}
$deprecatedIds = @{}
$publisherById = @{}
$nameById = @{}
$releaseById = @{}
foreach ($c in $catalog) {
    if (-not $c.connectorId) { continue }
    $tierById[$c.connectorId] = $c.tier
    $publisherById[$c.connectorId] = $c.publisher
    $nameById[$c.connectorId] = $c.displayName
    $releaseById[$c.connectorId] = $c.releaseTag
    if ($c.isDeprecated -eq 'true' -or $c.isDeprecated -eq $true) { $deprecatedIds[$c.connectorId] = $true }
}

$usedConnectors = @($nonEnv | ForEach-Object { $_.connectors } | Where-Object { $_ } | Sort-Object -Unique)

# Only built-in triggers carry a display name; connector triggers give an id, so resolve
# those against the catalog rather than reporting the interesting ones as Unknown.
foreach ($r in $nonEnv) {
    if (-not $r.triggerName) {
        $r.triggerName = if ($r.triggerConnId -and $nameById[$r.triggerConnId]) { $nameById[$r.triggerConnId] }
        elseif ($r.triggerConnId) { $r.triggerConnId }
        elseif ($r.triggerOpId) { 'Built in' }
        else { '' }
    }
    if (-not $r.triggerOp -and $r.triggerOpId) { $r.triggerOp = $r.triggerOpId }
}

$connectorUsage = @(
    $nonEnv | Where-Object { $_.connectors.Count -gt 0 } |
        ForEach-Object { $c = $_; $c.connectors | ForEach-Object { [pscustomobject]@{ connectorId = $_; res = $c.id } } } |
        Group-Object connectorId | Sort-Object Count -Descending |
        ForEach-Object {
            $id = $_.Name
            $label = if ($nameById[$id]) { $nameById[$id] } else { $id }
            if ($deprecatedIds.ContainsKey($id)) { $label = "$label (deprecated)" }
            [pscustomobject]@{ key = $label; count = $_.Count }
        }
)

function Group-Simple($pairs) {
    @($pairs | Group-Object | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{ key = if ($_.Name) { $_.Name } else { '(none)' }; count = $_.Count }
        })
}

# ---- admin API collection, everything Resource Graph does not carry ----
$script:deepSources = [ordered]@{}
$envDetail = @{}
$dlpRaw = @()
$envGroups = @()
$groupRuleRows = @()
$billingRows = @()
$tenantCapacity = $null
$tenantSettings = $null

if ($Deep -and $Demo) {
    $d = & (Join-Path $root 'demo-data.ps1') -Deep -Environments $DemoEnvironments
    $envDetail = $d.envDetail
    $dlpRaw = @($d.dlpPolicies)
    $envGroups = @($d.envGroups)
    $groupRuleRows = @($d.groupRules)
    $billingRows = @($d.billingPolicies)
    $tenantCapacity = $d.tenantCapacity
    $tenantSettings = $d.tenantSettings
    foreach ($k in $d.sources.Keys) { $script:deepSources[$k] = $d.sources[$k] }
}
elseif ($Deep) {
    Write-Host "Collecting admin API data (this is best effort; anything unavailable is reported)..." -ForegroundColor Cyan
    $pp = 'https://api.powerplatform.com'
    $resPp = 'https://api.powerplatform.com'
    $resBap = 'https://service.powerapps.com/'

    # The api.powerplatform.com route needs EnvironmentManagement.Environments.Read, which the
    # Azure PowerShell client is not consented for, so fall back to the BAP endpoint it can use.
    $envRows = @(Invoke-AdminApi -Label 'Environment detail' -Resource $resPp -Uri @(
            "$pp/environmentmanagement/environments?api-version=2024-10-01"
            "$pp/environmentmanagement/environments?api-version=2022-03-01-preview"))
    if (-not $envRows.Count) {
        $envRows = @(Invoke-AdminApi -Label 'Environment detail' -Resource $resBap -Uri @(
                'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&$expand=properties.capacity,properties.addons'))
    }
    foreach ($e in $envRows) {
        $key = if ($e.name) { $e.name } else { ($e.id -split '/')[-1] }
        if ($key) { $envDetail[$key] = $e }
    }

    # v1 is the only route that returns connectorGroups; v2 omits them entirely, which would
    # silently leave every connector on the default classification and find nothing.
    $dlpRaw = @(Invoke-AdminApi -Label 'Data policies' -Resource $resBap -Uri @(
            'https://api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies?api-version=2016-11-01'
            'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/apiPolicies?api-version=2016-11-01'))

    $envGroups = @(Invoke-AdminApi -Label 'Environment groups' -Resource $resPp -Uri @(
            "$pp/environmentmanagement/environmentGroups?api-version=2024-10-01"
            "$pp/environmentmanagement/environmentGroups?api-version=2022-03-01-preview"))

    foreach ($g in $envGroups) {
        $gid = if ($g.id) { ($g.id -split '/')[-1] } else { $g.name }
        foreach ($rs in @(Invoke-AdminApi -Label 'Environment group rules' -Resource $resPp -Uri @(
                    "$pp/governance/environmentGroups/$gid/ruleSets?api-version=2024-10-01"
                    "$pp/environmentmanagement/environmentGroups/$gid/ruleSets?api-version=2022-03-01-preview"))) {
            foreach ($rule in @($rs.rules ? $rs.rules : $rs.parameters)) {
                $groupRuleRows += [pscustomobject]@{
                    group = if ($g.displayName) { $g.displayName } else { $gid }
                    rule  = "$($rule.type)"
                    value = if ($null -ne $rule.value) { "$($rule.value)" } else { "$($rule.resourceType)" }
                }
            }
        }
    }
    $script:deepSources['Environment group rules'] = if ($groupRuleRows.Count) { "ok ($($groupRuleRows.Count))" } else { 'none found' }

    $billingRows = @(Invoke-AdminApi -Label 'Billing policies' -Resource $resPp -Uri @(
            "$pp/licensing/billingPolicies?api-version=2022-03-01-preview")) |
        ForEach-Object {
            [pscustomobject]@{ name = "$($_.name)"; status = "$($_.status)"; scope = "$($_.billingInstrument.resourceGroup)" }
        }

    $tc = Invoke-AdminApi -Label 'Tenant capacity' -Resource $resPp -Uri @(
        "$pp/licensing/tenantCapacity?api-version=2022-03-01-preview")
    if ($tc) { $tenantCapacity = $tc[0] }

    $ts = Invoke-AdminApi -Label 'Tenant settings' -Resource $resBap -Method POST -Body @{} -Uri @(
        'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/listtenantsettings?api-version=2020-08-01')
    if ($ts) { $tenantSettings = $ts[0] }
}

# ---- data policies: normalise, then work out what they actually hit ----
# Connectors a policy does not name fall into its default classification, so an
# unlisted connector is not automatically safe. Blocked wins over group crossing.
$classLabel = @{ Confidential = 'Business'; General = 'Non-business'; Blocked = 'Blocked' }
$policyView = @(
    foreach ($p in $dlpRaw) {
        $def = if ($p.policyDefinition) { $p.policyDefinition } else { $p }
        if (-not $def.displayName) { continue }

        $map = @{}
        $tally = @{ Business = 0; 'Non-business' = 0; Blocked = 0 }
        foreach ($g in @($def.connectorGroups)) {
            $label = if ($classLabel.ContainsKey("$($g.classification)")) { $classLabel["$($g.classification)"] } else { "$($g.classification)" }
            foreach ($c in @($g.connectors)) {
                $cid = if ($c.name) { "$($c.name)" } else { ("$($c.id)" -split '/')[-1] }
                if ($cid) { $map[$cid] = $label; $tally[$label] = 1 + [int]$tally[$label] }
            }
        }

        # v1 spells this defaultConnectorsClassification, the v2 shape drops the plural.
        $dc = if ($def.defaultConnectorsClassification) { "$($def.defaultConnectorsClassification)" } else { "$($def.defaultConnectorClassification)" }
        [pscustomobject]@{
            id          = "$($def.name)"
            name        = "$($def.displayName)"
            scope       = "$($def.environmentType)"
            envIds      = @(@($def.environments) | ForEach-Object { if ($_.name) { "$($_.name)" } else { ("$($_.id)" -split '/')[-1] } })
            map         = $map
            default     = if ($classLabel.ContainsKey($dc)) { $classLabel[$dc] } else { 'Non-business' }
            business    = [int]$tally['Business']
            nonBusiness = [int]$tally['Non-business']
            blocked     = [int]$tally['Blocked']
            modified    = "$($def.lastModifiedTime)"
        }
    }
)

$policyApplies = {
    param($pol, $envId)
    switch ($pol.scope) {
        'AllEnvironments' { $true }
        'OnlyEnvironments' { $pol.envIds -contains $envId }
        'ExceptEnvironments' { -not ($pol.envIds -contains $envId) }
        default { $pol.envIds -contains $envId }
    }
}

$policyByEnv = @{}
foreach ($e in $environments) {
    $policyByEnv[$e.id] = @($policyView | Where-Object { & $policyApplies $_ $e.id })
}

$connLabel = { param($id) if ($nameById[$id]) { $nameById[$id] } else { $id } }
$dlpFindings = [System.Collections.Generic.List[object]]::new()
$dlpBlocked = 0
$dlpCross = 0

foreach ($r in $nonEnv) {
    if (-not $r.connectors -or $r.connectors.Count -eq 0) { continue }
    foreach ($pol in @($policyByEnv[$r.envId])) {
        $seen = @{}
        $hits = @()
        foreach ($cid in $r.connectors) {
            $cls = if ($pol.map.ContainsKey($cid)) { $pol.map[$cid] } else { $pol.default }
            if (-not $seen.ContainsKey($cls)) { $seen[$cls] = [System.Collections.Generic.List[string]]::new() }
            $seen[$cls].Add((& $connLabel $cid))
            if ($cls -eq 'Blocked') { $hits += (& $connLabel $cid) }
        }

        $verdict = $null
        if ($hits.Count) { $verdict = 'Uses a blocked connector'; $dlpBlocked++ }
        elseif ($seen.ContainsKey('Business') -and $seen.ContainsKey('Non-business')) { $verdict = 'Crosses data groups'; $dlpCross++ }
        if (-not $verdict) { continue }

        $detail = if ($hits.Count) { "Blocked: $($hits -join ', ')" }
        else { "Business: $($seen['Business'] -join ', ') / Non-business: $($seen['Non-business'] -join ', ')" }

        if ($dlpFindings.Count -lt 500) {
            $dlpFindings.Add([pscustomobject]@{
                    name = $r.name; typeLabel = $r.typeLabel; envName = $r.envName
                    policy = $pol.name; verdict = $verdict; detail = $detail
                })
        }
    }
}

# ---- environment posture: one row per environment, everything an admin checks ----
$mb = { param($v) if ($null -eq $v) { $null } else { [math]::Round([double]$v / 1024, 1) } }

# The environment payload carries only a group id, so resolve names from the groups call.
$groupNames = @{}
foreach ($g in $envGroups) {
    $gid = if ($g.id) { ($g.id -split '/')[-1] } else { $g.name }
    if ($gid -and $g.displayName) { $groupNames[$gid] = "$($g.displayName)" }
}

$envPosture = @()
if ($envDetail.Count -or $dlpRaw.Count) {
    $envPosture = @(
        foreach ($e in $environments) {
            $d = $envDetail[$e.id]
            $cap = @{}
            foreach ($c in @($d.properties.capacity)) { $cap["$($c.capacityType)"] = $c.actualConsumption }
            $pols = @($policyByEnv[$e.id] | ForEach-Object { $_.name })

            [pscustomobject]@{
                name          = $e.name
                id            = $e.id
                envType       = $e.envType
                isManaged     = $e.isManaged
                resourceCount = $e.resourceCount
                sku           = "$($d.properties.environmentSku)"
                protection    = "$($d.properties.governanceConfiguration.protectionLevel)"
                group         = $(
                    $gid = if ($d.properties.parentEnvironmentGroup.id) { ("$($d.properties.parentEnvironmentGroup.id)" -split '/')[-1] }
                    elseif (@($d.properties.connectedGroups)[0].id) { ("$(@($d.properties.connectedGroups)[0].id)" -split '/')[-1] }
                    else { $e.envGroupId }
                    if ($gid -and $groupNames[$gid]) { $groupNames[$gid] } elseif ($gid) { $gid } else { '' }
                )
                dataverse     = [bool]$d.properties.linkedEnvironmentMetadata.instanceUrl
                cmk           = "$($d.properties.protectionStatus.keyManagedBy)"
                dbGb          = (& $mb $cap['Database'])
                fileGb        = (& $mb $cap['File'])
                logGb         = (& $mb $cap['Log'])
                policies      = $pols
                policyCount   = $pols.Count
            }
        }
    )
}

# ---- tenant settings: flatten, then flag only the ones that change who can do what ----
function Get-FlatSetting($obj, $prefix = '') {
    if ($null -eq $obj) { return }
    foreach ($p in $obj.PSObject.Properties) {
        $k = if ($prefix) { "$prefix.$($p.Name)" } else { "$($p.Name)" }
        if ($p.Value -is [pscustomobject]) { Get-FlatSetting $p.Value $k }
        elseif ($p.Value -isnot [array]) { [pscustomobject]@{ key = $k; leaf = "$($p.Name)"; value = "$($p.Value)" } }
    }
}

$watched = @{
    'disableEnvironmentCreationByNonAdminUsers'      = 'Anyone in the tenant can create environments'
    'disableTrialEnvironmentCreationByNonAdminUsers' = 'Anyone in the tenant can create trial environments'
    'disablePortalsCreationByNonAdminUsers'          = 'Anyone in the tenant can create Power Pages sites'
    'disableCapacityAllocationByEnvironmentAdmins'   = 'Environment admins can allocate tenant capacity'
    'disableBillingPolicyCreationByNonAdminUsers'    = 'Non-admins can create pay-as-you-go billing policies'
    'disableShareWithEveryone'                       = 'Makers can share an app with everyone in the tenant'
    'enableGuestsToMake'                             = 'Guest accounts can build apps'
    'disableAdminDigest'                             = 'The admin digest email is switched off'
}
$tenantSettingRows = @(
    Get-FlatSetting $tenantSettings | ForEach-Object {
        if (-not $watched.ContainsKey($_.leaf)) { return }
        $permissive = if ($_.leaf -like 'disable*') { $_.value -eq 'False' } else { $_.value -eq 'True' }
        [pscustomobject]@{ key = $_.key; value = $_.value; concern = $permissive; hint = $watched[$_.leaf] }
    }
)

$capacityRows = @(
    $envPosture | Where-Object { $_.dbGb } | Sort-Object dbGb -Descending |
        Select-Object -First 15 |
        ForEach-Object { [pscustomobject]@{ key = $_.name; count = $_.dbGb } }
)

$tenantCapacityRows = @(
    @($tenantCapacity.tenantCapacities) | ForEach-Object {
        [pscustomobject]@{
            key      = "$($_.capacityType)"
            actual   = (& $mb $_.consumption.actual)
            rated    = (& $mb $_.consumption.rated)
            entitled = (& $mb $_.totalCapacity)
            status   = "$($_.status)"
        }
    } | Where-Object { $_.actual -gt 0 -or $_.entitled -gt 0 }
)

$envNoPolicy = @($envPosture | Where-Object { $_.policyCount -eq 0 }).Count

# A tenant with no policies at all is the one that most needs telling, so this keys off
# whether the endpoint answered, not off how many policies came back.
$dlpReadable = "$($script:deepSources['Data policies'])" -like 'ok*'

# ---- adoption trend: resources created per month, last 24 months ----
$now = Get-Date
$trend = @()
for ($m = 23; $m -ge 0; $m--) {
    $bucket = $now.AddMonths(-$m)
    $key = '{0:yyyy-MM}' -f $bucket
    $n = @($nonEnv | Where-Object { $_.createdAt -and ('{0:yyyy-MM}' -f [datetime]$_.createdAt) -eq $key }).Count
    $trend += [pscustomobject]@{ key = $key; count = $n }
}

$thisMonth = '{0:yyyy-MM}' -f $now
$createdThisMonth = @($nonEnv | Where-Object { $_.createdAt -and ('{0:yyyy-MM}' -f [datetime]$_.createdAt) -eq $thisMonth }).Count

# ---- governance signals, mirroring CoE tenant-hygiene reporting ----
$staleCut = $now.AddDays(-180)
$defaultEnvIds = @($environments | Where-Object { $_.envType -eq 'Default' } | ForEach-Object { $_.id })
$flows = @($nonEnv | Where-Object { $_.type -like '*powerautomate*' })
$appsAndFlows = @($nonEnv | Where-Object { $_.type -like '*powerapps*' -or $_.type -like '*powerautomate*' -or $_.type -like '*copilotstudio*' })

# Premium usage drives per-user licensing, so surface resources not just connectors.
$premiumIds = @{}
foreach ($k in $tierById.Keys) { if ($tierById[$k] -and $tierById[$k] -ne 'Standard') { $premiumIds[$k] = $true } }
$premiumResources = @($appsAndFlows | Where-Object { @($_.connectors | Where-Object { $premiumIds.ContainsKey($_) }).Count -gt 0 })

# CoE calls these out because the connection is shared implicitly with every user.
$implicitShare = @('shared_sql', 'shared_azureblob', 'shared_filesystem', 'shared_ftp', 'shared_sftpwithssh')
$implicitResources = @($appsAndFlows | Where-Object { @($_.connectors | Where-Object { $implicitShare -contains $_ }).Count -gt 0 })

# A resource is only truly orphaned if it names an owner who no longer resolves.
# Model-driven apps never report one, so an empty ownerId is not an orphan.
$orphaned = @()
if ($graphChecked) {
    $orphaned = @($nonEnv | Where-Object { $_.ownerId -and -not $makerNames.ContainsKey($_.ownerId) })
}

# ---- archive score: the CoE idea rebuilt on inventory fields ----
# One point per signal, and every point is named on the resource so the number is auditable
# rather than a black box. CoE scores apps out of 6 and flows out of 10 using Dataverse
# fields we do not have; these eight signals are the subset ARG can actually evidence.
$nonProdWords = 'testing|test|demo|sample|poc|prototype|trial|temp|tmp|draft|copy|backup|obsolete|delete|untitled|old|dnu'
$nonProdRx = [regex]::new("(?i)(^|[\s_\-\(\[])($nonProdWords)([\s_\-\)\]0-9]|`$)")

# Only these types emit connector data, so "no connectors" is meaningless elsewhere.
$connectorAware = @(
    'microsoft.powerapps/canvasapps', 'microsoft.powerautomate/cloudflows',
    'microsoft.powerautomate/agentflows', 'microsoft.powerautomate/m365agentflows',
    'microsoft.copilotstudio/agents'
)

$orphanIds = @{}
foreach ($r in $orphaned) { $orphanIds[$r.id] = $true }

$connectorAwareSet = @{}
foreach ($t in $connectorAware) { $connectorAwareSet[$t] = $true }

$dupCount = @{}
foreach ($r in $nonEnv) {
    $k = '{0}|{1}' -f $r.envId, "$($r.name)".ToLowerInvariant()
    $dupCount[$k] = 1 + [int]$dupCount[$k]
}

$yearAgo = $now.AddDays(-365)
$bandTally = [ordered]@{ 'Critical (6+)' = 0; 'High (4-5)' = 0; 'Moderate (2-3)' = 0; 'Low (1)' = 0; 'Clean (0)' = 0 }
$tally = @{ neverModified = 0; nonProd = 0; duplicated = 0; atRisk = 0 }

# One pass over the whole set; tallies are accumulated here rather than rescanning per signal.
foreach ($r in $resources) {
    $why = [System.Collections.Generic.List[string]]::new()
    $isEnv = $containerTypes -contains $r.type

    if (-not $isEnv) {
        $created = if ($r.createdAt) { [datetime]$r.createdAt } else { $null }
        $modified = if ($r.modifiedAt) { [datetime]$r.modifiedAt } else { $null }

        if ($created -and $modified -and ($modified - $created).TotalHours -lt 1) {
            $why.Add('Never modified after creation'); $tally.neverModified++
        }
        if ($nonProdRx.IsMatch("$($r.name)")) { $why.Add('Non-production name'); $tally.nonProd++ }
        if ($created -and $created -lt $yearAgo) { $why.Add('Over a year old') }
        if ($modified -and $modified -lt $staleCut) { $why.Add('Untouched over 180 days') }
        if ($connectorAwareSet.ContainsKey($r.type) -and $r.connectors.Count -eq 0) { $why.Add('No connectors detected') }
        if ($r.quarantined) { $why.Add('Quarantined') }
        elseif ($r.status -and $r.status -ne 'Activated') { $why.Add("Flow is $($r.status.ToLower())") }
        if ($orphanIds.ContainsKey($r.id)) { $why.Add('Owner no longer in directory') }
        elseif (-not $r.ownerId -and $r.type -ne 'microsoft.powerapps/modeldrivenapps') { $why.Add('No owner recorded') }
        if ($dupCount['{0}|{1}' -f $r.envId, "$($r.name)".ToLowerInvariant()] -gt 1) {
            $why.Add('Duplicate name in the same environment'); $tally.duplicated++
        }
    }

    $s = $why.Count
    $r | Add-Member -NotePropertyName archiveScore -NotePropertyValue $s -Force
    $r | Add-Member -NotePropertyName archiveWhy -NotePropertyValue ($why -join '; ') -Force

    if ($isEnv) { continue }
    if ($s -ge 4) { $tally.atRisk++ }
    $bandTally[$(
        if ($s -ge 6) { 'Critical (6+)' } elseif ($s -ge 4) { 'High (4-5)' }
        elseif ($s -ge 2) { 'Moderate (2-3)' } elseif ($s -eq 1) { 'Low (1)' } else { 'Clean (0)' }
    )]++
}

$riskBuckets = @($bandTally.Keys | ForEach-Object { [pscustomobject]@{ key = $_; count = $bandTally[$_] } })
$atRisk = $tally.atRisk

$duplicates = @(
    $nonEnv | Group-Object { '{0}|{1}' -f $_.envId, "$($_.name)".ToLowerInvariant() } | Where-Object Count -GT 1 |
        Sort-Object Count -Descending | Select-Object -First 25 |
        ForEach-Object {
            $f = $_.Group[0]
            [pscustomobject]@{ key = "$($f.name) - $($f.envName)"; count = $_.Count }
        }
)

$namingHits = Group-Simple @(
    $nonEnv | ForEach-Object {
        $m = $nonProdRx.Match("$($_.name)")
        if ($m.Success) { (Get-Culture).TextInfo.ToTitleCase($m.Groups[2].Value.ToLower()) }
    }
)

# A maker building across many environments is either a platform team or unmanaged sprawl.
$makerSprawl = @(
    $nonEnv | Where-Object createdBy | Group-Object createdBy |
        ForEach-Object { [pscustomobject]@{ id = $_.Name; envs = @($_.Group | ForEach-Object { $_.envId } | Sort-Object -Unique).Count } } |
        Where-Object { $_.envs -gt 1 } | Sort-Object envs -Descending | Select-Object -First 15 |
        ForEach-Object { [pscustomobject]@{ key = (& $makerLabel $_.id); count = $_.envs } }
)

$hygiene = @(
    [pscustomobject]@{ key = 'Owner no longer in directory'; count = $orphaned.Count; hint = if ($graphChecked) { 'Truly orphaned; reassign before changes are needed' } else { 'Not checked - Graph lookup unavailable' } }
    [pscustomobject]@{ key = 'No owner recorded'; count = @($nonEnv | Where-Object { -not $_.ownerId }).Count; hint = 'Model-driven apps never report one; others are worth a look' }
    [pscustomobject]@{ key = 'Last edited by a non-owner'; count = @($nonEnv | Where-Object { $_.editedBy -and $_.ownerId -and $_.editedBy -ne $_.ownerId }).Count; hint = 'Ownership may already have moved in practice' }
    [pscustomobject]@{ key = 'Quarantined or blocked'; count = @($nonEnv | Where-Object { $_.quarantined }).Count; hint = 'Blocked from use pending review' }
    [pscustomobject]@{ key = 'Untouched over 180 days'; count = @($nonEnv | Where-Object { $_.modifiedAt -and [datetime]$_.modifiedAt -lt $staleCut }).Count; hint = 'Archive candidates' }
    [pscustomobject]@{ key = 'Never modified after creation'; count = $tally.neverModified; hint = 'Built once and abandoned' }
    [pscustomobject]@{ key = 'Non-production naming'; count = $tally.nonProd; hint = 'Test, demo, copy and similar left in production' }
    [pscustomobject]@{ key = 'Duplicate name in one environment'; count = $tally.duplicated; hint = 'Usually forgotten copies of the real thing' }
    [pscustomobject]@{ key = 'High archive score (4+)'; count = $atRisk; hint = 'Cleanup shortlist; see the Risk tab' }
    [pscustomobject]@{ key = 'In the default environment'; count = @($nonEnv | Where-Object { $defaultEnvIds -contains $_.envId }).Count; hint = 'Ungoverned by design; move to a managed environment' }
    [pscustomobject]@{ key = 'Suspended or stopped flows'; count = @($flows | Where-Object { $_.status -and $_.status -ne 'Activated' }).Count; hint = 'Often a data-policy or billing block' }
    [pscustomobject]@{ key = 'Using premium connectors'; count = $premiumResources.Count; hint = 'Each maker and user needs a premium licence' }
    [pscustomobject]@{ key = 'Implicitly shared connections'; count = $implicitResources.Count; hint = 'SQL auth and similar publish the connection to every user' }
    [pscustomobject]@{ key = 'Using third-party connectors'; count = @($appsAndFlows | Where-Object { @($_.connectors | Where-Object { $publisherById[$_] -and $publisherById[$_] -ne 'Microsoft' }).Count -gt 0 }).Count; hint = 'Data leaves via a publisher you do not control' }
    [pscustomobject]@{ key = 'Using preview connectors'; count = @($appsAndFlows | Where-Object { @($_.connectors | Where-Object { $releaseById[$_] -and $releaseById[$_] -notlike 'Production*' }).Count -gt 0 }).Count; hint = 'Not covered by production support commitments' }
    [pscustomobject]@{ key = 'Deprecated connectors in use'; count = @($usedConnectors | Where-Object { $deprecatedIds.ContainsKey($_) }).Count; hint = 'Scheduled for retirement by the publisher' }
    [pscustomobject]@{ key = 'Unmanaged environments'; count = @($environments | Where-Object { -not $_.isManaged }).Count; hint = 'Outside Managed Environments governance' }
    [pscustomobject]@{ key = 'Environments not in a group'; count = @($environments | Where-Object { -not $_.envGroupId }).Count; hint = 'Environment groups apply policy in bulk' }
    [pscustomobject]@{ key = 'Environments with nothing in them'; count = @($environments | Where-Object { $_.resourceCount -eq 0 }).Count; hint = 'Consuming capacity for no return' }
)

# Only shown when the policy data actually came back, so a zero never reads as "all clear".
if ($dlpReadable) {
    $hygiene += @(
        [pscustomobject]@{ key = 'Environments with no data policy'; count = $envNoPolicy; hint = 'Nothing stops a connector being used there' }
        [pscustomobject]@{ key = 'Resources using a blocked connector'; count = $dlpBlocked; hint = 'Already broken, or will break on next save' }
        [pscustomobject]@{ key = 'Resources crossing data groups'; count = $dlpCross; hint = 'Business and non-business connectors in one resource' }
    )
}

# ---- growth, the CoE year-over-year view ----
$monthOf = { param($d) if ($d) { '{0:yyyy-MM}' -f [datetime]$d } else { '' } }
$yearOf = { param($d) if ($d) { '{0:yyyy}' -f [datetime]$d } else { '' } }
$lastMonth = '{0:yyyy-MM}' -f $now.AddMonths(-1)
$thisYear = '{0:yyyy}' -f $now
$lastYear = '{0:yyyy}' -f $now.AddYears(-1)

$createdLastMonth = @($nonEnv | Where-Object { (& $monthOf $_.createdAt) -eq $lastMonth }).Count
$createdThisYear = @($nonEnv | Where-Object { (& $yearOf $_.createdAt) -eq $thisYear }).Count
$createdLastYear = @($nonEnv | Where-Object { (& $yearOf $_.createdAt) -eq $lastYear }).Count

$pct = { param($cur, $prev) if ($prev -gt 0) { [math]::Round((($cur - $prev) / [double]$prev) * 100) } elseif ($cur -gt 0) { $null } else { 0 } }

$growth = [ordered]@{
    thisMonth     = $createdThisMonth
    lastMonth     = $createdLastMonth
    monthPct      = & $pct $createdThisMonth $createdLastMonth
    thisYear      = $createdThisYear
    lastYear      = $createdLastYear
    yearPct       = & $pct $createdThisYear $createdLastYear
    thisYearLabel = $thisYear
    lastYearLabel = $lastYear
}

# CoE reports YoY per resource type, which is where the shape of adoption actually shows.
$yoyByType = @(
    $nonEnv | Group-Object typeLabel | Sort-Object Count -Descending | ForEach-Object {
        $cur = @($_.Group | Where-Object { (& $yearOf $_.createdAt) -eq $thisYear }).Count
        $prev = @($_.Group | Where-Object { (& $yearOf $_.createdAt) -eq $lastYear }).Count
        [pscustomobject]@{ key = $_.Name; count = $cur; prev = $prev; pct = (& $pct $cur $prev) }
    }
)

# ---- distributions only the inventory data makes possible ----
$ageBuckets = @(
    @{ k = '0-30 days'; lo = 0; hi = 30 }
    @{ k = '31-90 days'; lo = 30; hi = 90 }
    @{ k = '91-180 days'; lo = 90; hi = 180 }
    @{ k = '181-365 days'; lo = 180; hi = 365 }
    @{ k = 'Over a year'; lo = 365; hi = 100000 }
) | ForEach-Object {
    $b = $_
    $n = @($nonEnv | Where-Object {
            if (-not $_.createdAt) { return $false }
            $age = ($now - [datetime]$_.createdAt).TotalDays
            $age -ge $b.lo -and $age -lt $b.hi
        }).Count
    [pscustomobject]@{ key = $b.k; count = $n }
}

$depthBuckets = @(0, 1, 2, 3, 4) | ForEach-Object {
    $d = $_
    $n = if ($d -lt 4) { @($appsAndFlows | Where-Object { $_.connectors.Count -eq $d }).Count }
    else { @($appsAndFlows | Where-Object { $_.connectors.Count -ge 4 }).Count }
    [pscustomobject]@{ key = if ($d -lt 4) { "$d connectors" } else { '4 or more' }; count = $n }
}

$payload = [ordered]@{    tenant         = [ordered]@{
        id          = if ($Demo) { '00000000-0000-0000-0000-000000000000' } else { $ctx.Tenant.Id }
        account     = if ($Demo) { 'demo@contoso.onmicrosoft.com' } else { $ctx.Account.Id }
        generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    }
    counts         = [ordered]@{
        total            = $resources.Count
        environments     = @($resources | Where-Object type -eq 'microsoft.powerplatform/environments').Count
        apps             = @($resources | Where-Object { $_.type -like '*powerapps*' }).Count
        flows            = @($resources | Where-Object { $_.type -like '*powerautomate*' }).Count
        agents           = @($resources | Where-Object { $_.type -like '*copilotstudio*' }).Count
        connectorCatalog = $catalogCount
        connectorsInUse  = $usedConnectors.Count
        makers           = @($nonEnv | ForEach-Object { $_.createdBy } | Where-Object { $_ } | Sort-Object -Unique).Count
        createdThisMonth = $createdThisMonth
        managedEnvs      = @($environments | Where-Object isManaged).Count
        premiumPct       = if ($appsAndFlows.Count) { [math]::Round(($premiumResources.Count / [double]$appsAndFlows.Count) * 100) } else { 0 }
        appsAndFlows     = $appsAndFlows.Count
        atRisk           = $atRisk
        clean            = $bandTally['Clean (0)']
        duplicated       = $tally.duplicated
        nonProdNamed     = $tally.nonProd
        dlpPolicies      = $policyView.Count
        dlpBlocked       = $dlpBlocked
        dlpCross         = $dlpCross
        envNoPolicy      = $envNoPolicy
    }
    byType         = Group-Count $resources 'typeLabel'
    byRegion       = Group-Count $resources 'location'
    byEnvironment  = Group-Count $nonEnv 'envName'
    byEnvType      = Group-Count $environments 'envType'
    connectorUsage = $connectorUsage
    trend          = $trend
    growth         = $growth
    yoyByType      = $yoyByType
    hygiene        = $hygiene
    riskBuckets    = $riskBuckets
    duplicates     = $duplicates
    namingHits     = $namingHits
    makerSprawl    = $makerSprawl
    deep           = [ordered]@{
        requested = [bool]$Deep
        dlp       = $dlpReadable
        envDetail = ($envDetail.Count -gt 0)
        sources   = @($script:deepSources.Keys | ForEach-Object { [pscustomobject]@{ key = $_; value = "$($script:deepSources[$_])" } })
    }
    envPosture     = $envPosture
    dlpPolicyList  = @($policyView | ForEach-Object {
            [pscustomobject]@{
                name = $_.name; scope = $_.scope; envCount = $_.envIds.Count
                business = $_.business; nonBusiness = $_.nonBusiness; blocked = $_.blocked
                default = $_.default; modified = $_.modified
            }
        })
    dlpFindings    = @($dlpFindings)
    dlpVerdicts    = Group-Simple @($dlpFindings | ForEach-Object { $_.verdict })
    envPolicyMix   = Group-Simple @($envPosture | ForEach-Object { if ($_.policyCount -eq 0) { 'No policy' } elseif ($_.policyCount -eq 1) { 'One policy' } else { "$($_.policyCount) policies" } })
    capacityByEnv  = $capacityRows
    tenantCapacity = $tenantCapacityRows
    tenantSettings = $tenantSettingRows
    groupRules     = $groupRuleRows
    billingPolicies = $billingRows
    ageBuckets     = $ageBuckets
    connectorDepth = $depthBuckets
    byTrigger      = Group-Simple @($flows | ForEach-Object { if ($_.triggerName) { $_.triggerName } else { 'Unknown' } })
    byOperation    = @(
        Group-Simple @($appsAndFlows | ForEach-Object { $_.operations }) |
            Select-Object -First 12 |
            ForEach-Object {
                $parts = $_.key -split '\|', 2
                $cn = if ($nameById[$parts[0]]) { $nameById[$parts[0]] } else { $parts[0] }
                [pscustomobject]@{ key = "$cn - $($parts[1])"; count = $_.count }
            }
    )
    byEnvManaged   = Group-Simple @($environments | ForEach-Object { if ($_.isManaged) { 'Managed' } else { 'Unmanaged' } })
    byEnvGrouped   = Group-Simple @($environments | ForEach-Object { if ($_.envGroupId) { 'In a group' } else { 'Not in a group' } })
    connectorRel   = Group-Simple @($usedConnectors | ForEach-Object { if ($releaseById[$_]) { (Get-Culture).TextInfo.ToTitleCase($releaseById[$_].ToLower()) } else { 'Unknown' } })
    topEditors     = @(
        Group-Simple @($nonEnv | Where-Object { $_.editedBy } | ForEach-Object { $_.editedBy }) |
            Select-Object -First 15 |
            ForEach-Object { [pscustomobject]@{ key = (& $makerLabel $_.key); count = $_.count } }
    )
    byDepartment   = Group-Simple @(
        $nonEnv | ForEach-Object {
            $i = $makerInfo[$_.createdBy]
            if ($i -and $i.department) { $i.department } else { 'Not set' }
        }
    )
    byCountry      = Group-Simple @(
        $nonEnv | ForEach-Object {
            $i = $makerInfo[$_.createdBy]
            if ($i -and $i.country) { $i.country } else { 'Not set' }
        }
    )
    topMakers      = @(
        Group-Simple @($nonEnv | ForEach-Object { $_.createdBy }) |
            Select-Object -First 15 |
            ForEach-Object { [pscustomobject]@{ key = (& $makerLabel $_.key); count = $_.count } }
    )
    flowState      = Group-Simple @($flows | ForEach-Object { if ($_.status) { $_.status } else { 'Unknown' } })
    flowTrigger    = Group-Simple @($flows | ForEach-Object { if ($_.triggerType) { $_.triggerType } else { 'Unknown' } })
    connectorTier  = Group-Simple @($usedConnectors | ForEach-Object { if ($tierById[$_]) { $tierById[$_] } else { 'Unknown' } })
    connectorPub   = Group-Simple @($usedConnectors | ForEach-Object {
            $p = $publisherById[$_]
            if (-not $p) { 'Unknown' } elseif ($p -eq 'Microsoft') { 'Microsoft' } else { 'Third party' }
        })
    environments   = $environments
    resources      = $resources
}

$json = $payload | ConvertTo-Json -Depth 10 -Compress

if ($Password) {
    # AES-256-GCM with a PBKDF2 key. The HTML then holds ciphertext only, so this is
    # real confidentiality rather than a JavaScript gate that anyone can read past.
    $iterations = 600000
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    $salt = [byte[]]::new(16)
    $iv = [byte[]]::new(12)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.GetBytes($iv)

    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $plain, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $key = $kdf.GetBytes(32)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $cipher = [byte[]]::new($bytes.Length)
    $tag = [byte[]]::new(16)
    $aes = [System.Security.Cryptography.AesGcm]::new($key, 16)
    $aes.Encrypt($iv, $bytes, $cipher, $tag)
    $aes.Dispose(); $kdf.Dispose()
    [Array]::Clear($key, 0, $key.Length)

    # Web Crypto expects the auth tag appended to the ciphertext.
    $json = @{
        encrypted  = $true
        iterations = $iterations
        salt       = [Convert]::ToBase64String($salt)
        iv         = [Convert]::ToBase64String($iv)
        ct         = [Convert]::ToBase64String($cipher + $tag)
    } | ConvertTo-Json -Compress

    Write-Host "  payload encrypted with AES-256-GCM (PBKDF2-SHA256, $iterations iterations)" -ForegroundColor DarkGray
}

$template = Get-Content (Join-Path $root 'dashboard.template.html') -Raw

# The payload is embedded in an inline <script>, where the HTML parser wins over JSON
# escaping: a resource named "</script>" would close the tag and let the rest of the
# data be parsed as markup. Resource names are maker-controlled, so escape these as
# JSON unicode escapes, which JSON.parse turns back into the original characters.
$json = $json -replace '<', '\u003c' -replace '>', '\u003e' -replace '&', '\u0026'
$json = $json -replace "\u2028", '\u2028' -replace "\u2029", '\u2029'

$out = $template.Replace('"__PPDATA__"', $json)
Set-Content -Path $OutFile -Value $out -Encoding utf8

Write-Host "Wrote $OutFile ($($resources.Count) resources, $catalogCount connectors in catalog)" -ForegroundColor Green

# ---- apply a Purview sensitivity label ----
if ($SensitivityLabel) {
    if (Get-Command Set-FileLabel -ErrorAction SilentlyContinue) {
        # HTML is not a natively labelable type, so Purview wraps it as a .pfile.
        Set-FileLabel -Path $OutFile -LabelId $SensitivityLabel -PreserveFileDetails | Out-Null
        $labelled = if (Test-Path "$OutFile.pfile") { "$OutFile.pfile" } else { $OutFile }
        Write-Host "  labelled: $labelled" -ForegroundColor DarkGray
        if ($labelled -ne $OutFile) { $OutFile = $labelled }
    }
    else {
        Write-Warning @"
Set-FileLabel is unavailable, so no label was applied.
It ships with the Microsoft Purview Information Protection client (Windows only),
not the PowerShell Gallery: https://www.microsoft.com/download/details.aspx?id=53018
Then: Import-Module PurviewInformationProtection; Set-Authentication ...
"@
    }
}

# ---- upload to OneDrive or SharePoint and hand access to an Entra group ----
if ($UploadTo) {
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw "Upload needs Microsoft.Graph.Authentication: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # The Az token carries no Files scope, so this is a separate consent.
    $scopes = @('Files.ReadWrite')
    if ($ShareWithGroup) { $scopes += 'Group.Read.All' }
    Connect-MgGraph -Scopes $scopes -NoWelcome

    $leaf = Split-Path $OutFile -Leaf
    $target = ($UploadTo.Trim('/') + '/' + $leaf).TrimStart('/')
    $bytes = [IO.File]::ReadAllBytes($OutFile)

    $item = Invoke-MgGraphRequest -Method PUT `
        -Uri "https://graph.microsoft.com/v1.0/me/drive/root:/$($target):/content" `
        -Body $bytes -ContentType 'application/octet-stream'

    Write-Host "  uploaded: $($item.webUrl)" -ForegroundColor DarkGray

    if ($ShareWithGroup) {
        $grp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($ShareWithGroup -replace "'", "''")'&`$select=id,mail,displayName"
        $g = @($grp.value)[0]
        if (-not $g) { throw "Group '$ShareWithGroup' not found." }

        # roles=read and no sendInvitation keeps this an access grant, not a share link.
        $body = @{
            recipients    = @(@{ objectId = $g.id })
            roles         = @('read')
            requireSignIn = $true
            sendInvitation = $false
        } | ConvertTo-Json -Depth 5

        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$($item.id)/invite" `
            -Body $body -ContentType 'application/json' | Out-Null

        Write-Host "  granted read to '$($g.displayName)' only" -ForegroundColor DarkGray
    }
}

# ---- ephemeral: show it, then destroy it ----
if ($Ephemeral) {
    Write-Host "`nOpening the report. It will be deleted when you press Enter." -ForegroundColor Yellow
    Start-Process $OutFile
    [void](Read-Host "Press Enter to delete $OutFile")

    # Overwrite before unlinking. Best effort: on SSDs wear levelling may retain blocks.
    try {
        $len = (Get-Item $OutFile).Length
        $buf = [byte[]]::new($len)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
        [IO.File]::WriteAllBytes($OutFile, $buf)
    }
    catch {
        Write-Warning "Could not overwrite before deleting ($($_.Exception.Message)). The file is removed but its contents may be recoverable."
    }
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    Write-Host "Deleted. Nothing persisted to disk." -ForegroundColor Green
}
