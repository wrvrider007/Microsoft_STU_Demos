#Requires -Version 7.0
<#
.SYNOPSIS
    Starts cross-tenant synchronization provisioning jobs for community partners,
    once every partner tenant has applied Apply-GraphTemplate.ps1 with collaboration.json.

.DESCRIPTION
    The final step of cross-tenant sync (validate credentials -> start job) cannot
    run inside Apply-GraphTemplate.ps1 (collaboration.json) because it has a CROSS-TENANT precondition:
    validateCredentials only succeeds after the PARTNER (target) tenant has set
    userSyncInbound.isSyncAllowed = true for you - i.e. they've run the script too.

    This script is safe to run repeatedly as community tenants come online. For
    each partner it:
      1. Finds the "CTS - <Partner>" service principal + its sync job (from Apply).
      2. Calls validateCredentials against the target tenant.
      3. If validation succeeds (partner is ready), starts the job.
      4. If validation fails (partner not ready yet), reports and SKIPS - not an error.

.PARAMETER Domain
    One or more partner domains. Resolved to tenant IDs via OIDC (same as Apply).

.PARAMETER TenantId
    One or more partner tenant IDs (GUIDs).

.PARAMETER Environment
    Cloud/endpoint name. Global, USGov, and USGovDoD are built in; any other name
    (e.g. a sovereign/AGC cloud) must be defined in a clouds.json (see -CloudConfigPath).
    Default Global.

.PARAMETER CloudConfigPath
    Optional path to a clouds.json defining named cloud endpoints. If omitted, the
    script searches ..\Config\clouds.json, .\Config\clouds.json, and clouds.json beside
    the script (the last covers flat Azure Cloud Shell uploads). File entries override
    the built-in Global/USGov/USGovDoD definitions.

.PARAMETER WhatIf
    Shows what would validate/start without committing.

.EXAMPLE
    .\Start-CommunitySync.ps1 -Domain fabrikam.com -WhatIf

.EXAMPLE
    .\Start-CommunitySync.ps1 -TenantId 1111...,2222...
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string[]] $Domain,
    [string[]] $TenantId,

    [string] $Environment = 'Global',

    [string] $CloudConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Cloud / endpoint resolution
#
# Cloud definitions (Graph endpoint, login host, Graph SDK environment, Azure CLI
# cloud name) come from a clouds.json file so sovereign/AGC endpoints live in config
# instead of script parameters. The three public clouds are also defined in-script as
# a fallback, so a clouds.json is only REQUIRED for a custom/sovereign cloud name.
#
# clouds.json search order:
#   1. -CloudConfigPath (explicit)
#   2. <script>\..\Config\clouds.json   (repo layout: Scripts\ beside Config\)
#   3. <script>\Config\clouds.json
#   4. <script>\clouds.json             (flat Azure Cloud Shell upload)
# File entries override built-ins of the same name.
# ---------------------------------------------------------------------------
$BuiltInClouds = @{
    Global   = @{ graphEndpoint = 'https://graph.microsoft.com';   loginHost = 'login.microsoftonline.com'; mgEnvironment = 'Global';   azCloud = 'AzureCloud' }
    USGov    = @{ graphEndpoint = 'https://graph.microsoft.us';     loginHost = 'login.microsoftonline.us';  mgEnvironment = 'USGov';    azCloud = 'AzureUSGovernment' }
    USGovDoD = @{ graphEndpoint = 'https://dod-graph.microsoft.us'; loginHost = 'login.microsoftonline.us';  mgEnvironment = 'USGovDoD'; azCloud = 'AzureUSGovernment' }
}

function Resolve-CloudConfig {
    param([Parameter(Mandatory = $true)][string] $Name, [string] $ConfigPath)

    $candidates = @()
    if ($ConfigPath) { $candidates += $ConfigPath }
    if ($PSScriptRoot) {
        $candidates += (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config/clouds.json')
        $candidates += (Join-Path $PSScriptRoot 'Config/clouds.json')
        $candidates += (Join-Path $PSScriptRoot 'clouds.json')
    }

    $fileClouds = @{}
    $foundPath  = $null
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $foundPath = $c; break }
    }
    if ($foundPath) {
        try { $doc = Get-Content -Raw -LiteralPath $foundPath | ConvertFrom-Json }
        catch { throw "Cloud config '$foundPath' is not valid JSON: $($_.Exception.Message)" }
        $node = if ($doc.PSObject.Properties.Name -contains 'clouds') { $doc.clouds } else { $doc }
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -eq '$schema') { continue }
            $h = @{}
            foreach ($f in $p.Value.PSObject.Properties) { $h[$f.Name] = $f.Value }
            $fileClouds[$p.Name] = $h
        }
    }

    if     ($fileClouds.ContainsKey($Name))    { $entry = $fileClouds[$Name] }
    elseif ($BuiltInClouds.ContainsKey($Name)) { $entry = $BuiltInClouds[$Name] }
    else {
        $known    = ((@($BuiltInClouds.Keys) + @($fileClouds.Keys)) | Select-Object -Unique | Sort-Object) -join ', '
        $searched = ($candidates | Where-Object { $_ }) -join '; '
        throw "Unknown -Environment '$Name'. Known clouds: $known. Define a custom/sovereign cloud in a clouds.json (searched: $searched)."
    }
    if ($entry.graphEndpoint) { $entry.graphEndpoint = ([string]$entry.graphEndpoint).TrimEnd('/') }
    return $entry
}

$EnvCfg        = Resolve-CloudConfig -Name $Environment -ConfigPath $CloudConfigPath
$GraphEndpoint = $EnvCfg.graphEndpoint
$LoginHost     = $EnvCfg.loginHost
if (-not $GraphEndpoint -or -not $LoginHost -or -not $EnvCfg.mgEnvironment) {
    throw "Cloud '$Environment' must define graphEndpoint, loginHost, and mgEnvironment (check your clouds.json)."
}

$script:Summary = [ordered]@{ Started = 0; AlreadyRunning = 0; NotReady = 0; WhatIf = 0; Error = 0 }

function Write-Action {
    param(
        [ValidateSet('Started', 'AlreadyRunning', 'NotReady', 'WhatIf', 'Error', 'Info')]
        [string] $Kind,
        [string] $Message
    )
    $color = switch ($Kind) {
        'Started'        { 'Green' }
        'AlreadyRunning' { 'Cyan' }
        'NotReady'       { 'Yellow' }
        'WhatIf'         { 'Magenta' }
        'Error'          { 'Red' }
        default          { 'Gray' }
    }
    if ($script:Summary.Contains($Kind)) { $script:Summary[$Kind]++ }
    $tag = ('[{0}]' -f $Kind).PadRight(16)
    Write-Host $tag -ForegroundColor $color -NoNewline
    Write-Host " $Message"
}

function Resolve-TenantIdFromDomain {
    param([string] $DomainName)
    $url = "https://$LoginHost/$DomainName/v2.0/.well-known/openid-configuration"
    $meta = Invoke-RestMethod -Method GET -Uri $url -ErrorAction Stop
    if ($meta.issuer -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    throw "OIDC metadata for '$DomainName' did not contain a tenant GUID."
}

function Build-Partners {
    $list = [System.Collections.Generic.List[object]]::new()
    if ($Domain) {
        foreach ($d in $Domain) {
            $d = $d.Trim(); if (-not $d) { continue }
            $tid = Resolve-TenantIdFromDomain -DomainName $d
            $name = ($d -split '\.')[0]; $name = $name.Substring(0,1).ToUpper() + $name.Substring(1)
            $list.Add([pscustomobject]@{ tenantId = $tid; displayName = $name })
        }
    }
    if ($TenantId) {
        foreach ($t in $TenantId) {
            $t = $t.Trim(); if (-not $t) { continue }
            if ($t -notmatch '^[0-9a-fA-F-]{36}$') { throw "TenantId '$t' is not a valid GUID." }
            $list.Add([pscustomobject]@{ tenantId = $t; displayName = "Tenant-$($t.Substring(0,8))" })
        }
    }
    if ($list.Count -eq 0) { throw "Provide at least one -Domain or -TenantId." }
    return $list
}

Write-Host ""
Write-Host "=== Start Community Cross-Tenant Sync ===" -ForegroundColor White
Write-Host "Environment : $Environment ($GraphEndpoint)"
Write-Host "WhatIf      : $([bool]$WhatIfPreference)"
Write-Host ""

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @('Application.Read.All', 'Synchronization.ReadWrite.All', 'Directory.Read.All')
Write-Action Info "Connecting to Graph ($($EnvCfg.MgEnvironment)) ..."
Connect-MgGraph -Environment $EnvCfg.MgEnvironment -Scopes $scopes -NoWelcome

$partners = Build-Partners

foreach ($p in $partners) {
    $label = "$($p.displayName) ($($p.tenantId))"
    try {
        # 1. Locate the CTS service principal created by Apply-GraphTemplate.ps1 (collaboration.json)
        $spFilter = "displayName eq 'CTS - $($p.displayName)'"
        $spResp = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "$GraphEndpoint/v1.0/servicePrincipals?`$filter=$spFilter"
        $sp = if ($spResp.value) { @($spResp.value)[0] } else { $null }
        if (-not $sp) { Write-Action Error "$label - no 'CTS - $($p.displayName)' service principal found (apply collaboration.json with Apply-GraphTemplate.ps1 first)."; continue }
        $spId = $sp.id

        # 2. Locate the sync job
        $jobResp = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs"
        $job = if ($jobResp.value) { @($jobResp.value)[0] } else { $null }
        if (-not $job) { Write-Action Error "$label - no synchronization job on the CTS app."; continue }
        $jobId = $job.id

        # Is it already running?
        $statusCode = $null
        try { $statusCode = $job.status.code } catch { $statusCode = $null }
        if ($statusCode -in @('Active', 'InProgress')) {
            Write-Action AlreadyRunning "$label - job already active."
            continue
        }

        # 3. Validate credentials (fails until partner allowed inbound sync)
        $valBody = @{
            useSavedCredentials = $false
            templateId          = 'Azure2Azure'
            credentials         = @(
                @{ key = 'CompanyId';          value = $p.tenantId },
                @{ key = 'AuthenticationType'; value = 'SyncPolicy' }
            )
        }
        $ready = $false
        try {
            Invoke-MgGraphRequest -Method POST `
                -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs/validateCredentials" `
                -Body ($valBody | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
            $ready = $true
        } catch {
            $ready = $false
        }
        if (-not $ready) {
            Write-Action NotReady "$label - partner has not enabled inbound sync yet; skipping. Re-run later."
            continue
        }

        # 4. Start the job
        if ($PSCmdlet.ShouldProcess($label, "start synchronization job")) {
            Invoke-MgGraphRequest -Method POST `
                -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs/$jobId/start" | Out-Null
            Write-Action Started "$label - provisioning job started."
        } else {
            Write-Action WhatIf "$label - would start provisioning job (partner is ready)."
        }
    } catch {
        Write-Action Error "$label - $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor White
foreach ($k in $script:Summary.Keys) { Write-Host ("  {0,-15}: {1}" -f $k, $script:Summary[$k]) }
Write-Host ""
if ($script:Summary['NotReady'] -gt 0) {
    Write-Host "Some partners were not ready. Re-run this script after they onboard." -ForegroundColor Yellow
}
