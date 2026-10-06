#Requires -Version 7.0
<#
.SYNOPSIS
    Configures cross-tenant synchronization attribute mappings for community partners.

.DESCRIPTION
    This is a SEPARATE companion to Apply-GraphTemplate.ps1 (collaboration.json).
    Run it after the collaboration template creates each CTS - <Partner> app/job and
    before starting synchronization in the portal or with Start-CommunitySync.ps1.

    The script updates the user displayName mapping so synchronized users are
    visibly marked as file/resource-sharing identities, nudging Teams users to
    use federated external chat instead of the local synced object.

    Example result:
      Source displayName "Masse, Andrew", -OrgLabel ABC, -SharingSuffix "File Sharing Only"
      Target displayName "Masse, Andrew [ABC] - File Sharing Only"

.PARAMETER Domain
    One or more partner domains. Resolved to tenant IDs via OIDC (same as Apply).

.PARAMETER TenantId
    One or more partner tenant IDs (GUIDs).

.PARAMETER OrgLabel
    Optional organization label appended in brackets before the sharing suffix.
    If omitted or empty, no brackets are added.

.PARAMETER SharingSuffix
    Suffix appended to synchronized display names. Default: File Sharing Only.

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
    Shows what schema changes would be applied without committing.

.EXAMPLE
    .\Configure-CommunitySyncMappings.ps1 -Domain fabrikam.com -OrgLabel FAB -WhatIf

.EXAMPLE
    .\Configure-CommunitySyncMappings.ps1 -TenantId 11111111-1111-1111-1111-111111111111 -SharingSuffix "File Sharing Only (No Teams Chat)"
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string[]] $Domain,
    [string[]] $TenantId,

    [string] $OrgLabel,

    [ValidateNotNullOrEmpty()]
    [string] $SharingSuffix = 'File Sharing Only',

    [string] $Environment = 'Global',

    [string] $CloudConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$script:Summary = [ordered]@{ Applied = 0; AlreadyConfigured = 0; WhatIf = 0; Error = 0 }

function Write-Action {
    param(
        [ValidateSet('Applied', 'AlreadyConfigured', 'WhatIf', 'Error', 'Info')]
        [string] $Kind,
        [string] $Message
    )
    $color = switch ($Kind) {
        'Applied'           { 'Green' }
        'AlreadyConfigured' { 'Cyan' }
        'WhatIf'            { 'Magenta' }
        'Error'             { 'Red' }
        default             { 'Gray' }
    }
    if ($script:Summary.Contains($Kind)) { $script:Summary[$Kind]++ }
    $tag = ('[{0}]' -f $Kind).PadRight(20)
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

function ConvertTo-ExpressionStringLiteral {
    param([Parameter(Mandatory = $true)][string] $Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Find-DisplayNameMappings {
    param([Parameter(Mandatory = $true)] $Schema)

    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in @($Schema.synchronizationRules)) {
        foreach ($mapping in @($rule.objectMappings)) {
            foreach ($attributeMapping in @($mapping.attributeMappings)) {
                if ($attributeMapping.targetAttributeName -eq 'displayName') {
                    $matches.Add([pscustomobject]@{
                        Rule             = $rule
                        ObjectMapping    = $mapping
                        AttributeMapping = $attributeMapping
                    })
                }
            }
        }
    }
    return @($matches)
}

$orgLabelValue = if ([string]::IsNullOrWhiteSpace($OrgLabel)) { $null } else { $OrgLabel.Trim() }
$suffixValue = $SharingSuffix.Trim()
$appendValue = if ($orgLabelValue) { " [$orgLabelValue] - $suffixValue" } else { " - $suffixValue" }
$maxDisplayNameLength = 256
$prefixLength = $maxDisplayNameLength - $appendValue.Length
if ($prefixLength -lt 1) {
    throw "OrgLabel + SharingSuffix are too long. Appended value length is $($appendValue.Length); it must leave at least one character for the source displayName."
}
$expression = "Append(Left([displayName], $prefixLength), $(ConvertTo-ExpressionStringLiteral -Value $appendValue))"

Write-Host ""
Write-Host "=== Configure Community Sync Mappings ===" -ForegroundColor White
Write-Host "Environment  : $Environment ($GraphEndpoint)"
Write-Host "OrgLabel     : $(if ($orgLabelValue) { $orgLabelValue } else { '<none>' })"
Write-Host "SharingSuffix: $suffixValue"
Write-Host "Append value : $appendValue"
Write-Host "Expression   : $expression"
Write-Host "WhatIf       : $([bool]$WhatIfPreference)"
Write-Host ""

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @('Application.Read.All', 'Synchronization.ReadWrite.All', 'Directory.Read.All')
Write-Action Info "Connecting to Graph ($($EnvCfg.MgEnvironment)) ..."
Connect-MgGraph -Environment $EnvCfg.MgEnvironment -Scopes $scopes -NoWelcome

$partners = Build-Partners

foreach ($p in $partners) {
    $label = "$($p.displayName) ($($p.tenantId))"
    try {
        $spFilter = "displayName eq 'CTS - $($p.displayName)'"
        $spResp = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "$GraphEndpoint/v1.0/servicePrincipals?`$filter=$spFilter"
        $sp = if ($spResp.value) { @($spResp.value)[0] } else { $null }
        if (-not $sp) { Write-Action Error "$label - no 'CTS - $($p.displayName)' service principal found (apply collaboration.json first)."; continue }
        $spId = $sp.id

        $jobResp = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs"
        $job = if ($jobResp.value) { @($jobResp.value)[0] } else { $null }
        if (-not $job) { Write-Action Error "$label - no synchronization job on the CTS app."; continue }
        $jobId = $job.id

        $schema = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs/$jobId/schema"

        $mappings = @(Find-DisplayNameMappings -Schema $schema)
        if ($mappings.Count -eq 0) {
            Write-Action Error "$label - no displayName attribute mapping found in the synchronization schema."
            continue
        }

        $parseBody = @{ expression = $expression; targetAttributeDefinition = $null } | ConvertTo-Json -Depth 20
        $parseResult = Invoke-MgGraphRequest -Method POST -OutputType PSObject `
            -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs/$jobId/schema/parseExpression" `
            -Body $parseBody -ContentType 'application/json'
        if (-not $parseResult.parsingSucceeded -or -not $parseResult.parsedExpression) {
            $errorMessage = if ($parseResult.error) { ($parseResult.error | ConvertTo-Json -Depth 10) } else { 'Unknown parse error.' }
            Write-Action Error "$label - displayName expression did not parse: $errorMessage"
            continue
        }

        $changed = $false
        foreach ($mappingRef in $mappings) {
            $currentExpression = $mappingRef.AttributeMapping.source.expression
            if ($currentExpression -ne $expression) {
                $mappingRef.AttributeMapping.source = $parseResult.parsedExpression
                $changed = $true
            }
        }

        if (-not $changed) {
            Write-Action AlreadyConfigured "$label - displayName mapping already uses the requested expression."
            continue
        }

        $schemaBody = [ordered]@{
            id                   = $schema.id
            directories          = $schema.directories
            synchronizationRules = $schema.synchronizationRules
            version              = $schema.version
        }
        $json = $schemaBody | ConvertTo-Json -Depth 100

        if ($PSCmdlet.ShouldProcess($label, "update synchronization displayName mapping")) {
            Invoke-MgGraphRequest -Method PUT `
                -Uri "$GraphEndpoint/v1.0/servicePrincipals/$spId/synchronization/jobs/$jobId/schema" `
                -Body $json -ContentType 'application/json' | Out-Null
            Write-Action Applied "$label - displayName mapping updated."
        } else {
            Write-Action WhatIf "$label - would update $($mappings.Count) displayName mapping(s)."
        }
    } catch {
        Write-Action Error "$label - $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor White
foreach ($k in $script:Summary.Keys) { Write-Host ("  {0,-19}: {1}" -f $k, $script:Summary[$k]) }
Write-Host ""
