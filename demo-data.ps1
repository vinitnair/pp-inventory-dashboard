# Synthetic inventory shaped exactly like the Azure Resource Graph result set.
# Used by export-inventory.ps1 -Demo so the dashboard can be previewed without a tenant.
# Every name, GUID and owner here is invented.

param(
    [int]$Environments = 4,
    [switch]$Catalog,
    [switch]$MakerNames,
    [switch]$Deep
)

$people = @(
    @{ id = 'aaaaaaaa-0000-4000-8000-000000000001'; name = 'Priya Raman'; dept = 'Finance'; country = 'United States' }
    @{ id = 'aaaaaaaa-0000-4000-8000-000000000002'; name = 'Tom Whitfield'; dept = 'Operations'; country = 'United Kingdom' }
    @{ id = 'aaaaaaaa-0000-4000-8000-000000000003'; name = 'Aisha Bello'; dept = 'Human Resources'; country = 'United States' }
    @{ id = 'aaaaaaaa-0000-4000-8000-000000000004'; name = 'Lars Andersen'; dept = 'Operations'; country = 'Sweden' }
    @{ id = 'aaaaaaaa-0000-4000-8000-000000000005'; name = 'Mei Chen'; dept = 'IT'; country = 'Australia' }
    @{ id = 'aaaaaaaa-0000-4000-8000-000000000006'; name = 'Diego Fuentes'; dept = 'Field Services'; country = 'Spain' }
)

if ($MakerNames) {
    $map = @{}
    foreach ($p in $people) {
        $map[$p.id] = @{ name = $p.name; department = $p.dept; country = $p.country; city = ''; enabled = $true }
    }
    return $map
}

$catalogSpec = @(
    @{ id = 'shared_sharepointonline'; name = 'SharePoint'; tier = 'Standard'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_office365'; name = 'Office 365 Outlook'; tier = 'Standard'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_sql'; name = 'SQL Server'; tier = 'Premium'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_teams'; name = 'Microsoft Teams'; tier = 'Standard'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_commondataserviceforapps'; name = 'Microsoft Dataverse'; tier = 'Premium'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_excelonlinebusiness'; name = 'Excel Online (Business)'; tier = 'Standard'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_onedriveforbusiness'; name = 'OneDrive for Business'; tier = 'Standard'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_approvals'; name = 'Approvals'; tier = 'Standard'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_azureblob'; name = 'Azure Blob Storage'; tier = 'Premium'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_uiflow'; name = 'Desktop flows'; tier = 'Premium'; pub = 'Microsoft'; dep = 'false' }
    @{ id = 'shared_openai'; name = 'OpenAI'; tier = 'Premium'; pub = 'Contoso Labs'; dep = 'false' }
    @{ id = 'shared_legacycrm'; name = 'Legacy CRM (Independent Publisher)'; tier = 'Premium'; pub = 'R. Wilson'; dep = 'true' }
)

if ($Catalog) {
    return @($catalogSpec | ForEach-Object {
            [pscustomobject]@{
                connectorId  = $_.id
                displayName  = $_.name
                tier         = $_.tier
                publisher    = $_.pub
                releaseTag   = if ($_.pub -eq 'Microsoft') { 'Production' } else { 'Preview' }
                isDeprecated = $_.dep
            }
        })
}

$baseEnvs = @(
    @{ id = '11111111-1111-4111-8111-111111111111'; name = 'Contoso (default)'; region = 'unitedstates'; type = 'Default'; managed = 'false' }
    @{ id = '22222222-2222-4222-8222-222222222222'; name = 'HR Production'; region = 'unitedstates'; type = 'Production'; managed = 'true' }
    @{ id = '33333333-3333-4333-8333-333333333333'; name = 'Finance Production'; region = 'europe'; type = 'Production'; managed = 'true' }
    @{ id = '44444444-4444-4444-8444-444444444444'; name = 'Field Ops Sandbox'; region = 'australia'; type = 'Sandbox'; managed = 'false' }
)

$envs = $baseEnvs[0..([Math]::Min($Environments, $baseEnvs.Count) - 1)]

# Pad out to the requested size for scale testing.
$regions = @('unitedstates', 'europe', 'australia', 'canada', 'india', 'japan', 'unitedkingdom', 'brazil')
$types = @('Production', 'Sandbox', 'Developer', 'Trial')
for ($n = $baseEnvs.Count; $n -lt $Environments; $n++) {
    $envs += @{
        id      = '{0:x8}-eeee-4eee-8eee-{1:x12}' -f $n, $n
        name    = 'Team {0:D4} {1}' -f $n, $types[$n % $types.Count]
        region  = $regions[$n % $regions.Count]
        type    = $types[$n % $types.Count]
        managed = @('true', 'false')[$n % 2]
    }
}

$catalogIds = @($catalogSpec | ForEach-Object { $_.id })

# Synthetic admin API responses, shaped like the real ones so -Deep can be previewed offline.
if ($Deep) {
    $rngD = [Random]::new(20260813)
    $conn = { param($id) [pscustomobject]@{ name = $id; id = "/providers/Microsoft.PowerApps/apis/$id" } }

    $detail = @{}
    $i = 0
    foreach ($e in $envs) {
        $i++
        $detail[$e.id] = [pscustomobject]@{
            name       = $e.id
            properties = [pscustomobject]@{
                displayName               = $e.name
                environmentSku            = $e.type
                governanceConfiguration   = [pscustomobject]@{ protectionLevel = if ($e.managed -eq 'true') { 'Standard' } else { 'Basic' } }
                capacity                  = @(
                    [pscustomobject]@{ capacityType = 'Database'; actualConsumption = $rngD.Next(400, 42000); capacityUnit = 'MB' }
                    [pscustomobject]@{ capacityType = 'File'; actualConsumption = $rngD.Next(100, 95000); capacityUnit = 'MB' }
                    [pscustomobject]@{ capacityType = 'Log'; actualConsumption = $rngD.Next(0, 3500); capacityUnit = 'MB' }
                )
                protectionStatus          = [pscustomobject]@{ keyManagedBy = if ($e.managed -eq 'true') { 'Customer' } else { 'Microsoft' } }
                linkedEnvironmentMetadata = [pscustomobject]@{ instanceUrl = if ($e.type -eq 'Developer') { $null } else { "https://demo$i.crm.dynamics.com/" } }
                parentEnvironmentGroup    = [pscustomobject]@{ displayName = if ($e.managed -eq 'true') { 'Regulated' } else { $null } }
            }
        }
    }

    $policies = @(
        [pscustomobject]@{
            policyDefinition = [pscustomobject]@{
                name                            = 'p0000000-0000-4000-8000-000000000001'
                displayName                     = 'Tenant default policy'
                environmentType                 = 'AllEnvironments'
                environments                    = @()
                defaultConnectorsClassification = 'General'
                lastModifiedTime                = (Get-Date).AddDays(-64).ToString('o')
                connectorGroups                 = @(
                    [pscustomobject]@{ classification = 'Confidential'; connectors = @(
                            (& $conn 'shared_sql'), (& $conn 'shared_commondataserviceforapps'),
                            (& $conn 'shared_sharepointonline'), (& $conn 'shared_office365')) }
                    [pscustomobject]@{ classification = 'Blocked'; connectors = @(
                            (& $conn 'shared_legacycrm'), (& $conn 'shared_openai')) }
                    [pscustomobject]@{ classification = 'General'; connectors = @(
                            (& $conn 'shared_teams'), (& $conn 'shared_approvals')) }
                )
            }
        }
        [pscustomobject]@{
            policyDefinition = [pscustomobject]@{
                name                            = 'p0000000-0000-4000-8000-000000000002'
                displayName                     = 'Finance restricted'
                environmentType                 = 'OnlyEnvironments'
                environments                    = @($envs | Where-Object { $_.name -like 'Finance*' } | ForEach-Object { [pscustomobject]@{ name = $_.id } })
                defaultConnectorsClassification = 'Confidential'
                lastModifiedTime                = (Get-Date).AddDays(-11).ToString('o')
                connectorGroups                 = @(
                    [pscustomobject]@{ classification = 'Blocked'; connectors = @(
                            (& $conn 'shared_azureblob'), (& $conn 'shared_uiflow')) }
                    [pscustomobject]@{ classification = 'General'; connectors = @(
                            (& $conn 'shared_excelonlinebusiness'), (& $conn 'shared_onedriveforbusiness')) }
                )
            }
        }
    )

    return @{
        envDetail       = $detail
        dlpPolicies     = $policies
        envGroups       = @([pscustomobject]@{ id = 'gggggggg-0000-4000-8000-000000000001'; displayName = 'Regulated' })
        groupRules      = @(
            [pscustomobject]@{ group = 'Regulated'; rule = 'Sharing'; value = 'Limit sharing to 20 people' }
            [pscustomobject]@{ group = 'Regulated'; rule = 'SolutionChecker'; value = 'Block on high severity' }
            [pscustomobject]@{ group = 'Regulated'; rule = 'MakerOnboarding'; value = 'Enabled' }
            [pscustomobject]@{ group = 'Regulated'; rule = 'AdminDigest'; value = 'Weekly' }
            [pscustomobject]@{ group = 'Regulated'; rule = 'Copilot'; value = 'Off' }
        )
        billingPolicies = @([pscustomobject]@{ name = 'PAYG - Shared services'; status = 'Enabled'; scope = 'rg-powerplatform' })
        tenantCapacity  = [pscustomobject]@{
            tenantCapacities = @(
                [pscustomobject]@{ capacityType = 'Database'; totalCapacity = 204800; consumption = [pscustomobject]@{ actual = 151000; rated = 151000 }; status = 'Warning' }
                [pscustomobject]@{ capacityType = 'File'; totalCapacity = 1048576; consumption = [pscustomobject]@{ actual = 310000; rated = 310000 }; status = 'Normal' }
                [pscustomobject]@{ capacityType = 'Log'; totalCapacity = 20480; consumption = [pscustomobject]@{ actual = 4100; rated = 4100 }; status = 'Normal' }
            )
        }
        tenantSettings  = [pscustomobject]@{
            disableEnvironmentCreationByNonAdminUsers      = $false
            disableTrialEnvironmentCreationByNonAdminUsers = $false
            disablePortalsCreationByNonAdminUsers          = $true
            disableCapacityAllocationByEnvironmentAdmins   = $true
            powerPlatform                                  = [pscustomobject]@{
                powerApps  = [pscustomobject]@{ disableShareWithEveryone = $false; enableGuestsToMake = $true }
                governance = [pscustomobject]@{ disableAdminDigest = $false }
                licensing  = [pscustomobject]@{ disableBillingPolicyCreationByNonAdminUsers = $true }
            }
        }
        sources         = [ordered]@{
            'Environment detail'      = "ok ($($envs.Count))"
            'Data policies'           = 'ok (2)'
            'Environment groups'      = 'ok (1)'
            'Environment group rules' = 'ok (5)'
            'Billing policies'        = 'ok (1)'
            'Tenant capacity'         = 'ok (1)'
            'Tenant settings'         = 'ok (1)'
        }
    }
}

$rng = [Random]::new(20260811)
$rows = [System.Collections.Generic.List[object]]::new()

function addRow($props) { $rows.Add([pscustomobject]$props) }

foreach ($e in $envs) {
    addRow @{
        name = $e.id; type = 'microsoft.powerplatform/environments'; location = $e.region
        displayName = $e.name; environmentId = ''; environmentType = $e.type
        isManaged = $e.managed; createdBy = $people[0].id
        createdAt = (Get-Date).AddDays(-$rng.Next(120, 700)).ToString('o')
        modifiedAt = (Get-Date).AddDays(-$rng.Next(1, 60)).ToString('o')
        ownerId = ''; editedBy = $people[0].id; isQuarantined = 'false'; subType = ''
        envGroupId = if ($e.managed -eq 'true') { 'gggggggg-0000-4000-8000-000000000001' } else { '' }
        status = ''; flowTriggerType = ''; triggerName = ''; triggerOp = ''; connectors = $null
    }
}

$specs = @(
    @{ t = 'microsoft.powerapps/canvasapps'; names = @('Expense Capture', 'Site Safety Walk', 'Asset Tagger', 'Visitor Check-in', 'Shift Swap', 'Stock Count') }
    @{ t = 'microsoft.powerapps/modeldrivenapps'; names = @('Case Management', 'Recruitment Hub', 'Vendor Onboarding') }
    @{ t = 'microsoft.powerautomate/cloudflows'; names = @('Invoice Approval', 'New Hire Provisioning', 'Nightly SAP Sync', 'Expense Reminder', 'Contract Expiry Alert', 'Ticket Escalation', 'Weekly Ops Digest') }
    @{ t = 'microsoft.powerautomate/agentflows'; names = @('Lookup Order Status', 'Reset Password') }
    @{ t = 'microsoft.copilotstudio/agents'; names = @('HR Assistant', 'IT Helpdesk Agent', 'Finance FAQ Bot', 'Field Service Copilot') }
)

$guid = { param($i) ('{0:x8}-0000-4000-8000-{1:x12}' -f $i, $i) }
$idx = 100

# Each named resource is emitted once per environment group so resource volume
# scales with environment count the way it does in a real tenant.
$copies = [Math]::Max(1, [Math]::Ceiling($envs.Count / 4))

foreach ($s in $specs) {
    foreach ($n in $s.names) {
      foreach ($copy in 1..$copies) {
        $idx++
        $e = $envs[$rng.Next(0, $envs.Count)]
        $isFlow = $s.t -like '*powerautomate*'
        $isApp = $s.t -like '*powerapps*'

        $conns = $null
        if ($isFlow -or $isApp -or $s.t -like '*copilotstudio*') {
            # Seeded RNG throughout, so the demo report is byte-reproducible.
            $pick = @($catalogIds | Sort-Object { $rng.Next() } | Select-Object -First $rng.Next(1, 5))
            $opNames = @('Invoke', 'GetItems', 'PostItem', 'SendEmail', 'CreateRecord')
            $conns = @($pick | ForEach-Object {
                    [pscustomobject]@{
                        connectorId = $_
                        operations  = @([pscustomobject]@{ operationId = $opNames[$rng.Next(0, $opNames.Count)] })
                    }
                })
        }

        addRow @{
            name = (& $guid $idx); type = $s.t; location = $e.region
            displayName = if ($copies -gt 1) { "$n $copy" } else { $n }
            environmentId = $e.id; environmentType = ''
            isManaged = 'false'; createdBy = $people[$rng.Next(0, $people.Count)].id
            createdAt = (Get-Date).AddDays(-$rng.Next(5, 700)).ToString('o')
            modifiedAt = (Get-Date).AddDays(-$rng.Next(0, 400)).ToString('o')
            # A slice is left ownerless, some point at a departed maker, and a few are quarantined.
            ownerId = if ($rng.Next(0, 10) -lt 2) { '' } elseif ($rng.Next(0, 12) -eq 0) { 'dddddddd-0000-4000-8000-00000000dead' } else { $people[$rng.Next(0, $people.Count)].id }
            isQuarantined = if ($rng.Next(0, 25) -eq 0) { 'true' } else { 'false' }
            subType = ''; envGroupId = ''
            editedBy = $people[$rng.Next(0, $people.Count)].id
            status = if ($isFlow) { @('Activated', 'Activated', 'Activated', 'Suspended', 'Stopped')[$rng.Next(0, 5)] } else { '' }
            flowTriggerType = if ($isFlow) { @('Instant', 'Scheduled', 'Automated')[$rng.Next(0, 3)] } else { '' }
            triggerName = if ($isFlow) { @('Manually trigger a flow', 'Recurrence', 'SharePoint', 'Office 365 Outlook')[$rng.Next(0, 4)] } else { '' }
            triggerOp = if ($isFlow) { @('Manually trigger a flow', 'Recurrence', 'When an item is created', 'When a new email arrives')[$rng.Next(0, 4)] } else { '' }
            connectors = $conns
        }
      }
    }
}

# Deliberately messy records so the Risk tab has something to show without a real tenant.
$messy = @(
    @{ n = 'Expense Capture'; t = 'microsoft.powerapps/canvasapps' }
    @{ n = 'Expense Capture'; t = 'microsoft.powerapps/canvasapps' }
    @{ n = 'Copy of Invoice Approval'; t = 'microsoft.powerautomate/cloudflows' }
    @{ n = 'TEST - Payroll Import'; t = 'microsoft.powerautomate/cloudflows' }
    @{ n = 'Old Timesheet Sync'; t = 'microsoft.powerautomate/cloudflows' }
    @{ n = 'Asset Tagger DEMO'; t = 'microsoft.powerapps/canvasapps' }
)

foreach ($m in $messy) {
    $idx++
    $stamp = (Get-Date).AddDays(-$rng.Next(400, 900)).ToString('o')
    addRow @{
        name = (& $guid $idx); type = $m.t; location = $envs[0].region
        displayName = $m.n; environmentId = $envs[0].id; environmentType = ''
        isManaged = 'false'; createdBy = $people[$rng.Next(0, $people.Count)].id
        createdAt = $stamp; modifiedAt = $stamp
        ownerId = ''; isQuarantined = 'false'; subType = ''; envGroupId = ''
        editedBy = ''
        status = if ($m.t -like '*powerautomate*') { 'Stopped' } else { '' }
        flowTriggerType = if ($m.t -like '*powerautomate*') { 'Scheduled' } else { '' }
        triggerConnId = ''
        triggerName = if ($m.t -like '*powerautomate*') { 'Recurrence' } else { '' }
        triggerOpId = ''
        triggerOp = if ($m.t -like '*powerautomate*') { 'Recurrence' } else { '' }
        connectors = $null
    }
}

$rows
