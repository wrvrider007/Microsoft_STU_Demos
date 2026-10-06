#Requires -Version 7.0
<#
.SYNOPSIS
    Configures tenant-wide SharePoint Online and OneDrive sharing settings for
    the collaboration TCG.

.DESCRIPTION
    This is a SEPARATE companion to Apply-GraphTemplate.ps1 (collaboration.json).
    SharePoint Online sharing settings live in the SharePoint Online Management
    Shell (SPO PowerShell), not Microsoft Graph, so they cannot be driven by the
    JSON/Graph engine.

    The baseline matches the SharePoint admin center sharing screenshot:
    - SharePoint external sharing: Existing guests.
    - OneDrive external sharing: Existing guests.
    - Default file/folder link: Only people in your organization.
    - Default sharing-link permission: View.

    The SharePoint admin center also shows UI-only/default-on options for viewer
    names and short links. The script reports those as manual verification items
    because the current public Set-SPOTenant reference does not expose stable
    parameters for them.

.PARAMETER AdminUrl
    SharePoint admin center URL, for example https://contoso-admin.sharepoint.com.

.PARAMETER UseSystemBrowser
    Uses MSAL system-browser authentication for Connect-SPOService.

.PARAMETER Region
    Optional SPO authentication region passed to Connect-SPOService, for example ITAR.

.PARAMETER WhatIf
    Shows the tenant settings that would be applied without calling Set-SPOTenant.

.EXAMPLE
    .\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com -WhatIf

.EXAMPLE
    .\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com -UseSystemBrowser
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        $uri = $null
        if (-not [System.Uri]::TryCreate($_, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
        return $uri.Scheme -eq 'https'
    })]
    [string] $AdminUrl,

    [switch] $UseSystemBrowser,

    [string] $Region
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Action {
    param(
        [ValidateSet('Set', 'Found', 'Report', 'Skipped', 'WhatIf', 'Error', 'Info')]
        [string] $Kind,
        [string] $Message
    )
    $color = switch ($Kind) {
        'Set'     { 'Green' }
        'Found'   { 'Cyan' }
        'Report'  { 'Blue' }
        'Skipped' { 'DarkGray' }
        'WhatIf'  { 'Magenta' }
        'Error'   { 'Red' }
        default   { 'Gray' }
    }
    $tag = ('[{0}]' -f $Kind).PadRight(9)
    Write-Host $tag -ForegroundColor $color -NoNewline
    Write-Host " $Message"
}

function Test-CommandParameter {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommandName,

        [Parameter(Mandatory = $true)]
        [string] $ParameterName
    )
    $command = Get-Command $CommandName -ErrorAction Stop
    return $command.Parameters.ContainsKey($ParameterName)
}

function Add-IfSupported {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Table,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [object] $Value
    )
    if (Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName $Name) {
        $Table[$Name] = $Value
    } else {
        Write-Action Skipped "Set-SPOTenant parameter '$Name' is not available in the installed SPO module."
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return '<not returned>'
}

Write-Host ""
Write-Host "=== SharePoint Online Sharing Baseline ===" -ForegroundColor White
Write-Host "AdminUrl : $AdminUrl"
Write-Host "Region   : $(if ($Region) { $Region } else { 'Default' })"
Write-Host "WhatIf   : $([bool]$WhatIfPreference)"
Write-Host ""

if (-not (Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable)) {
    throw "Microsoft.Online.SharePoint.PowerShell module not found. Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser"
}

$importParams = @{ Name = 'Microsoft.Online.SharePoint.PowerShell'; ErrorAction = 'Stop' }
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $importParams.UseWindowsPowerShell = $true
}
Import-Module @importParams

$connectParams = @{ Url = $AdminUrl }
if ($UseSystemBrowser) { $connectParams.UseSystemBrowser = $true }
if ($Region) { $connectParams.Region = $Region }

Write-Action Info "Connecting to SharePoint Online ..."
Connect-SPOService @connectParams

$desired = [ordered]@{}

if ((Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName 'CoreSharingCapability') -and
    (Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName 'OneDriveSharingCapability')) {
    $desired.CoreSharingCapability = 'ExistingExternalUserSharingOnly'
    $desired.OneDriveSharingCapability = 'ExistingExternalUserSharingOnly'
} else {
    Add-IfSupported -Table $desired -Name 'SharingCapability' -Value 'ExistingExternalUserSharingOnly'
}

if ((Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName 'CoreDefaultShareLinkScope') -and
    (Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName 'OneDriveDefaultShareLinkScope')) {
    $desired.CoreDefaultShareLinkScope = 'Organization'
    $desired.OneDriveDefaultShareLinkScope = 'Organization'
} else {
    Add-IfSupported -Table $desired -Name 'DefaultSharingLinkType' -Value 'Internal'
}

if ((Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName 'CoreDefaultShareLinkRole') -and
    (Test-CommandParameter -CommandName 'Set-SPOTenant' -ParameterName 'OneDriveDefaultShareLinkRole')) {
    $desired.CoreDefaultShareLinkRole = 'View'
    $desired.OneDriveDefaultShareLinkRole = 'View'
} else {
    Add-IfSupported -Table $desired -Name 'DefaultLinkPermission' -Value 'View'
}

if ($desired.Count -eq 0) {
    throw "No supported Set-SPOTenant sharing parameters were found in the installed SPO module."
}

$tenant = Get-SPOTenant

Write-Action Info "Current tenant values:"
foreach ($name in $desired.Keys) {
    Write-Action Report ("  {0} = {1}" -f $name, (Get-PropertyValue -Object $tenant -Name $name))
}

$domainRestrictionMode = Get-PropertyValue -Object $tenant -Name 'SharingDomainRestrictionMode'
Write-Action Report "  SharingDomainRestrictionMode = $domainRestrictionMode"
if ($domainRestrictionMode -and $domainRestrictionMode -ne '<not returned>' -and $domainRestrictionMode -ne 'None') {
    $domainListProperty = if ($domainRestrictionMode -eq 'AllowList') { 'SharingAllowedDomainList' } else { 'SharingBlockedDomainList' }
    $domainList = Get-PropertyValue -Object $tenant -Name $domainListProperty
    Write-Action Report "  $domainListProperty = $domainList"
    Write-Action Warning "Domain-restricted external sharing is configured. If using an allow-list, it must include every community tenant domain or SharePoint/OneDrive sharing can block otherwise valid collaboration."
}

Write-Host ""
Write-Action Info "Desired tenant values:"
foreach ($entry in $desired.GetEnumerator()) {
    Write-Action Report ("  {0} = {1}" -f $entry.Key, $entry.Value)
}

Write-Host ""
if ($PSCmdlet.ShouldProcess('SharePoint Online tenant', 'apply TCG sharing baseline')) {
    Set-SPOTenant @desired
    Write-Action Set "SharePoint Online sharing baseline applied."
} else {
    Write-Action WhatIf "Would call Set-SPOTenant with the desired values above."
}

Write-Host ""
Write-Host "Manual verification in SharePoint admin center > Policies > Sharing:" -ForegroundColor White
Write-Host "  - Show owners the names of people who viewed their files in OneDrive: selected" -ForegroundColor White
Write-Host "  - Let site owners choose to display viewer names in SharePoint: selected" -ForegroundColor White
Write-Host "  - Use short links for sharing files and folders: selected" -ForegroundColor White
Write-Host ""
Write-Host "Done." -ForegroundColor White
