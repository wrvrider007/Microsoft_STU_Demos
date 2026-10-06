#Requires -Version 7.0
<#
.SYNOPSIS
    Configures organizational Teams federation globally or for a collaboration group.

.DESCRIPTION
    Companion to Apply-GraphTemplate.ps1; requires the MicrosoftTeams module.
    Inventories tenant federation, external access policies, direct user assignments,
    group assignments, and the selected meeting policy before making any changes.
    Read failures stop the run. A change preview and explicit y are required to apply.

    Global preserves existing allowed domains and enables the Global external access
    policy. Custom user/group policies remain in effect and are not overwritten.

    CollaborationGroupOnly disables federation in the Global external access policy
    and assigns a domain-specific policy to the supplied security-group object ID.
    Conflicting federation-enabled assignments must be reconciled manually first.
    Tenant domain lists and unrelated policies/assignments are left unchanged.
    Only direct group members inherit the policy; propagation is asynchronous.

    These scopes govern organizational federation, not every Teams communication
    path. Group-chat participant enforcement has documented gaps. Guest identities,
    shared channels, consumer access, meetings, and meeting chat need separate controls.
    Use -SetRestrictedMeetingBaseline to configure the selected meeting policy with the
    required collaboration meeting defaults after reviewing the preview.

.PARAMETER Domains
    Partner DNS domains. Global adds them to the tenant allow-list; group scope
    uses exactly these domains in the managed custom policy (maximum 100).

.PARAMETER ExternalCollaborationScope
    Global (default, compatible with existing invocations) or CollaborationGroupOnly.

.PARAMETER CollaborationGroupId
    Required for CollaborationGroupOnly. Object ID of the existing security group
    Community Collab Sync - All. Community Collaboration - All is the access package,
    not that group's name. No Graph connection or display-name lookup is added.
    The Teams service validates the group when assigning the policy, before the
    script changes the Global policy or tenant federation switch.

.PARAMETER ReportOnly
    Inventory and preview only. No mutation or continuation prompt.

.PARAMETER SetLobbyBypassForFederated
    Opt-in. Sets AutoAdmittedUsers to EveryoneInSameAndFederatedCompany on the
    selected meeting policy. This is independent of the federation scope and is
    not an attendee authorization boundary.

.PARAMETER SetRestrictedMeetingBaseline
    Opt-in. Sets the selected meeting policy to the required collaboration meeting
    defaults: trusted-org outbound meeting join, in-meeting-only chat excluding
    anonymous users, nontrusted external meeting chat disabled, anonymous start
    disabled, PSTN lobby bypass disabled, and organizer/co-organizer-only lobby
    admission authority.

.PARAMETER MeetingPolicyIdentity
    Meeting policy to read/set. Default Global.

.EXAMPLE
    .\Configure-TeamsCollaboration.ps1 -Domains contoso.com -ExternalCollaborationScope Global -WhatIf

.EXAMPLE
    .\Configure-TeamsCollaboration.ps1 -Domains contoso.com -ExternalCollaborationScope CollaborationGroupOnly -CollaborationGroupId '<security-group-object-id>' -ReportOnly
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [Alias('Domain')]
    [string[]] $Domains,

    [ValidateSet('Global', 'CollaborationGroupOnly')]
    [string] $ExternalCollaborationScope = 'Global',

    [guid] $CollaborationGroupId,

    [switch] $ReportOnly,

    [switch] $SetLobbyBypassForFederated,

    [switch] $SetRestrictedMeetingBaseline,

    [ValidateNotNullOrEmpty()]
    [string] $MeetingPolicyIdentity = 'Global'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$groupOnly = $ExternalCollaborationScope -eq 'CollaborationGroupOnly'
if ($groupOnly -and ($null -eq $CollaborationGroupId -or $CollaborationGroupId -eq [guid]::Empty)) {
    throw "CollaborationGroupOnly requires -CollaborationGroupId with the object ID of Community Collab Sync - All (the security group, not the Community Collaboration - All access package)."
}
if (-not $groupOnly -and $PSBoundParameters.ContainsKey('CollaborationGroupId')) {
    throw "-CollaborationGroupId is only valid with -ExternalCollaborationScope CollaborationGroupOnly."
}

$targetDomains = @($Domains | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_)) { throw "Partner domains must not be empty." }
    $domain = $_.Trim().ToLowerInvariant()
    if ($domain -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw "Invalid partner DNS domain '$domain'. Supply domains, not URLs, wildcards, or tenant IDs."
    }
    $domain
} | Sort-Object -Unique)
if ($targetDomains.Count -eq 0) { throw "At least one partner domain must be supplied." }
if ($groupOnly -and $targetDomains.Count -gt 100) {
    throw "Custom external access policies support at most 100 partner domains."
}

function Write-Action {
    param(
        [ValidateSet('Set', 'Found', 'Report', 'Skipped', 'WhatIf', 'Error', 'Info')]
        [string] $Kind,
        [string] $Message
    )
    $color = switch ($Kind) {
        'Set' { 'Green' }
        'Found' { 'Cyan' }
        'Report' { 'Blue' }
        'Skipped' { 'DarkGray' }
        'WhatIf' { 'Magenta' }
        'Error' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ('[{0}]' -f $Kind).PadRight(9) -ForegroundColor $color -NoNewline
    Write-Host " $Message"
}

function Get-RequiredProperty {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "Safety inventory did not return required property '$Name'. No changes have been applied."
    }
    $Object.$Name
}

function Get-PolicyName {
    param([AllowNull()] [string] $Identity)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return 'Global' }
    $Identity -replace '^Tag:', ''
}

function Get-DomainNames {
    param([AllowNull()] [object[]] $Values)
    foreach ($value in $Values) {
        $domain = if ($value -is [string]) { $value } else { Get-RequiredProperty $value 'Domain' }
        if ([string]::IsNullOrWhiteSpace($domain)) { throw "Safety inventory returned an empty domain." }
        $domain.Trim().ToLowerInvariant()
    }
}

Write-Host "`n=== Teams Community Collaboration ==="
Write-Host "Scope   : $ExternalCollaborationScope"
Write-Host "Domains : $($targetDomains -join ', ')"
Write-Host "Group ID: $(if ($groupOnly) { $CollaborationGroupId } else { '<not applicable>' })"
Write-Host "Preview : $([bool]($ReportOnly -or $WhatIfPreference))`n"

if (-not (Get-Module MicrosoftTeams -ListAvailable)) {
    throw "MicrosoftTeams module not found. Install-Module MicrosoftTeams -Scope CurrentUser"
}
Import-Module MicrosoftTeams -ErrorAction Stop
if (-not (Get-CsTenant -ErrorAction SilentlyContinue)) {
    Write-Action Info "Connecting to Microsoft Teams ..."
    Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
}

# Complete all safety reads and capability checks before the first mutation.
$fed = Get-CsTenantFederationConfiguration -ErrorAction Stop
$tenantEnabled = Get-RequiredProperty $fed 'AllowFederatedUsers'
if ($tenantEnabled -isnot [bool]) { throw "AllowFederatedUsers was not returned as a Boolean." }
$allowed = Get-RequiredProperty $fed 'AllowedDomains'
$blockedDomains = @(Get-DomainNames @(Get-RequiredProperty $fed 'BlockedDomains') | Sort-Object -Unique)
$blockSubdomains = Get-RequiredProperty $fed 'BlockAllSubdomains'
if ($blockSubdomains -isnot [bool]) { throw "BlockAllSubdomains was not returned as a Boolean." }
$allowAll = $false
$currentDomains = @()
if ($null -ne $allowed) {
    if ($null -ne $allowed.PSObject.Properties['AllowedDomain']) {
        $currentDomains = @(Get-DomainNames @($allowed.AllowedDomain) | Sort-Object -Unique)
    } elseif ([string]$allowed -eq 'AllowAllKnownDomains' -or $allowed.GetType().Name -match 'AllowAllKnownDomains') {
        $allowAll = $true
    } else {
        throw "Unrecognized tenant AllowedDomains representation. No changes have been applied."
    }
}

$policies = @(Get-CsExternalAccessPolicy -ErrorAction Stop)
$policyByName = @{}
foreach ($policy in $policies) {
    $identity = Get-RequiredProperty $policy 'Identity'
    if ([string]::IsNullOrWhiteSpace($identity)) { throw "External access policy identity was not returned." }
    $name = Get-PolicyName $identity
    $enabled = Get-RequiredProperty $policy 'EnableFederationAccess'
    if ($enabled -isnot [bool] -or $policyByName.ContainsKey($name)) {
        throw "Invalid or duplicate external access policy '$name' in safety inventory."
    }
    $policyByName[$name] = $policy
    Write-Action Report "Policy '$name': EnableFederationAccess = $enabled"
    foreach ($field in 'CommunicationWithExternalOrgs', 'AllowedExternalDomains', 'BlockedExternalDomains') {
        if ($null -ne $policy.PSObject.Properties[$field]) {
            Write-Action Report "  $field = $($policy.$field -join ', ')"
        }
    }
}
if (-not $policyByName.ContainsKey('Global')) { throw "Global external access policy was not returned." }
$globalPolicy = $policyByName['Global']
$groupAssignments = @(Get-CsGroupPolicyAssignment -PolicyType ExternalAccessPolicy -ErrorAction Stop)
foreach ($assignment in $groupAssignments) {
    $group = Get-RequiredProperty $assignment 'GroupId'
    $policyName = Get-RequiredProperty $assignment 'PolicyName'
    if ([string]::IsNullOrWhiteSpace($policyName)) { throw "Group assignment policy name was not returned." }
    $name = Get-PolicyName $policyName
    $rank = Get-RequiredProperty $assignment 'Rank'
    $parsedGroup = [guid]::Empty
    if (-not [guid]::TryParse([string]$group, [ref]$parsedGroup) -or $parsedGroup -eq [guid]::Empty -or
        $null -eq $rank -or [int]$rank -lt 1 -or -not $policyByName.ContainsKey($name)) {
        throw "Incomplete group policy assignment in safety inventory."
    }
    Write-Action Report "Group $group -> '$name' (rank $rank)"
}

# Numeric ResultSize works with current Teams modules; 'Unlimited' does not.
$users = @(Get-CsOnlineUser -Properties UserPrincipalName -ResultSize 2147483647 -ErrorAction Stop)
$directAssignments = @(foreach ($user in $users) {
    $upn = Get-RequiredProperty $user 'UserPrincipalName'
    if (-not $upn) { throw "User inventory has no UserPrincipalName." }
    $userPolicies = @(Get-CsUserPolicyAssignment -Identity $upn -PolicyType ExternalAccessPolicy -ErrorAction Stop)
    foreach ($userPolicy in $userPolicies) {
        $sources = @(Get-RequiredProperty $userPolicy 'PolicySource')
        if ($sources.Count -eq 0) { throw "Policy sources were not returned for '$upn'." }
        foreach ($source in $sources) {
            $sourceName = Get-RequiredProperty $source 'PolicyName'
            if ([string]::IsNullOrWhiteSpace($sourceName)) { throw "Policy source name was not returned for '$upn'." }
            $name = Get-PolicyName $sourceName
            $type = Get-RequiredProperty $source 'AssignmentType'
            if (-not $policyByName.ContainsKey($name) -or $type -notin 'Direct', 'Group') {
                throw "Unknown policy or assignment source for '$upn'."
            }
            if ($type -eq 'Direct' -and $name -ne 'Global') {
                Write-Action Report "Direct user $upn -> '$name'"
                [pscustomobject]@{ User = $upn; PolicyName = $name }
            } elseif ($type -eq 'Group') {
                $reference = Get-RequiredProperty $source 'Reference'
                $matching = @($groupAssignments | Where-Object {
                    $_.GroupId -eq $reference -and (Get-PolicyName $_.PolicyName) -eq $name
                })
                if ($matching.Count -ne 1) {
                    throw "Group assignment source for '$upn' is not consistent with the group inventory. Wait for propagation/reconcile assignments and retry."
                }
            }
        }
    }
})
Write-Action Report "Inventoried $($users.Count) users; $($directAssignments.Count) custom direct assignments."

$mp = Get-CsTeamsMeetingPolicy -Identity $MeetingPolicyIdentity -ErrorAction Stop
$lobby = Get-RequiredProperty $mp 'AutoAdmittedUsers'
if ([string]::IsNullOrWhiteSpace($lobby)) { throw "Meeting-policy lobby setting was not returned." }
foreach ($field in 'AutoAdmittedUsers', 'AllowAnonymousUsersToJoinMeeting',
    'AnonymousUserAuthenticationMethod', 'AllowAnonymousUsersToStartMeeting',
    'AllowPSTNUsersToBypassLobby', 'ExternalMeetingJoin', 'MeetingChatEnabledType',
    'AllowExternalNonTrustedMeetingChat', 'UsersCanAdmitFromLobby') {
    if ($null -ne $mp.PSObject.Properties[$field]) {
        Write-Action Report "Meeting policy '$MeetingPolicyIdentity': $field = $($mp.$field)"
    }
}
Write-Action Report "Tenant AllowFederatedUsers = $tenantEnabled"
Write-Action Report "Tenant allowed domains: $(if ($allowAll) { '<all known domains>' } elseif ($currentDomains.Count) { $currentDomains -join ', ' } else { '<none>' })"
Write-Action Report "Tenant blocked domains: $($blockedDomains -join ', '); BlockAllSubdomains = $blockSubdomains"

$plan = [System.Collections.Generic.List[string]]::new()
$conflicts = [System.Collections.Generic.List[string]]::new()
foreach ($domain in $targetDomains) {
    foreach ($blocked in $blockedDomains) {
        if ($domain -eq $blocked -or ($blockSubdomains -and $domain.EndsWith(".$blocked"))) {
            $conflicts.Add("Requested domain '$domain' is covered by tenant block '$blocked'. Reconcile that restriction manually first; explicit allow-lists can bypass tenant blocks.")
        }
    }
}

$desiredGlobal = -not $groupOnly
$changeGlobal = $globalPolicy.EnableFederationAccess -ne $desiredGlobal
if ($changeGlobal) { $plan.Add("Global external access policy: EnableFederationAccess -> $desiredGlobal") }
$changeTenant = -not $tenantEnabled
$changeDomains = $false
$changePolicy = $false
$changeAssignment = $false
$changeMeetingBaseline = $false
$managedPolicyName = "TCG-CommunityCollaboration-$CollaborationGroupId"

if ($groupOnly) {
    $managedPolicy = $policyByName[$managedPolicyName]
    if ($null -ne $managedPolicy) {
        $policyDomains = @((Get-RequiredProperty $managedPolicy 'AllowedExternalDomains') |
            ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
        $changePolicy = -not $managedPolicy.EnableFederationAccess -or
            (Get-RequiredProperty $managedPolicy 'CommunicationWithExternalOrgs') -ne 'AllowSpecificExternalDomains' -or
            (@(Compare-Object $targetDomains $policyDomains).Count -gt 0) -or
            (Get-RequiredProperty $managedPolicy 'EnableTeamsConsumerAccess') -ne $false -or
            (Get-RequiredProperty $managedPolicy 'EnableTeamsConsumerInbound') -ne $false -or
            (Get-RequiredProperty $managedPolicy 'EnableAcsFederationAccess') -ne $false
    } else {
        $changePolicy = $true
    }
    if ($changePolicy) {
        $plan.Add("Create/update '$managedPolicyName': allow exactly $($targetDomains -join ', '); unmanaged consumer and ACS access disabled")
    }
    $targetAssignments = @($groupAssignments | Where-Object { $_.GroupId -eq $CollaborationGroupId.ToString() })
    if ($targetAssignments.Count -gt 1) { throw "Multiple external access assignments were returned for the selected group." }
    $assignmentRank = if ($targetAssignments.Count) {
        [int]$targetAssignments[0].Rank
    } elseif ($groupAssignments.Count) {
        $maximumRank = [int]($groupAssignments | Measure-Object Rank -Maximum).Maximum
        if ($maximumRank -eq [int]::MaxValue) { throw "No available group assignment rank." }
        $maximumRank + 1
    } else { 1 }
    $changeAssignment = $targetAssignments.Count -eq 0 -or
        (Get-PolicyName $targetAssignments[0].PolicyName) -ne $managedPolicyName
    if ($changeAssignment) { $plan.Add("Assign '$managedPolicyName' to group $CollaborationGroupId at rank $assignmentRank") }

    # Without a Graph membership read, refuse ambiguous exceptions conservatively.
    foreach ($assignment in $directAssignments) {
        if ($assignment.PolicyName -eq $managedPolicyName -or $policyByName[$assignment.PolicyName].EnableFederationAccess) {
            $conflicts.Add("Direct assignment for '$($assignment.User)' to '$($assignment.PolicyName)' may permit federation outside the collaboration group. Remove/reconcile it manually first.")
        }
    }
    foreach ($assignment in $groupAssignments) {
        $name = Get-PolicyName $assignment.PolicyName
        if ($assignment.GroupId -ne $CollaborationGroupId.ToString() -and
            ($name -eq $managedPolicyName -or $policyByName[$name].EnableFederationAccess)) {
            $conflicts.Add("Group '$($assignment.GroupId)' has federation-capable policy '$name'. Reconcile it manually before selecting CollaborationGroupOnly.")
        }
    }
    Write-Warning "CollaborationGroupOnly disables the Global federation default. Existing direct restrictive policies and higher-ranked group policies still win; some selected members may remain blocked."
    Write-Warning "Group scope is not an all-Teams boundary: group chats, guest identities, shared channels, meetings, and meeting chat have separate controls or gaps."
    Write-Action Info "Tenant domain lists are preserved. Group ID must identify the intended existing security group; only direct members inherit the policy."
} else {
    $customPolicies = @($policies | Where-Object { (Get-PolicyName $_.Identity) -ne 'Global' })
    if ($customPolicies.Count) {
        Write-Warning "Custom external access policies exist: $(($customPolicies | ForEach-Object { Get-PolicyName $_.Identity }) -join ', '). Global does NOT override direct/group assignments. These policies are preserved and may override tenant domain defaults; enabling the tenant master switch can reactivate them."
    }
    $mergedDomains = @($currentDomains + $targetDomains | Sort-Object -Unique)
    if ($mergedDomains.Count -gt 4000) { throw "Tenant allowed-domain lists support at most 4,000 domains." }
    $changeDomains = $allowAll -or @(Compare-Object $currentDomains $mergedDomains).Count -gt 0
    if ($changeDomains) { $plan.Add("Tenant allowed domains -> $($mergedDomains -join ', ') (existing explicit allowed domains preserved)") }
    if ($allowAll) { Write-Warning "Global will replace allow-all-known-domains with an explicit allow-list. Other currently reachable domains will no longer be allowed by the tenant default." }
    if ($blockedDomains.Count -and $changeDomains) {
        Write-Warning "Tenant BlockedDomains are preserved but ignored when the tenant uses an explicit AllowedDomains list."
    }
}
if ($changeTenant) { $plan.Add("Tenant federation master switch: AllowFederatedUsers -> True") }
$changeLobby = $SetLobbyBypassForFederated -and $lobby -ne 'EveryoneInSameAndFederatedCompany'
if ($changeLobby) {
    $plan.Add("Meeting policy '$MeetingPolicyIdentity': AutoAdmittedUsers -> EveryoneInSameAndFederatedCompany")
    Write-Warning "Lobby bypass applies to the selected meeting policy independently of federation group membership. A lobby is not a hard deny."
}
$meetingBaseline = [ordered]@{
    ExternalMeetingJoin = 'EnabledForTrustedOrgs'
    MeetingChatEnabledType = 'EnabledInMeetingOnlyForAllExceptAnonymous'
    AllowExternalNonTrustedMeetingChat = $false
    AllowAnonymousUsersToStartMeeting = $false
    AllowPSTNUsersToBypassLobby = $false
    UsersCanAdmitFromLobby = 'OrganizerAndCoOrganizersOnly'
}
if ($SetRestrictedMeetingBaseline) {
    foreach ($field in $meetingBaseline.Keys) {
        $current = Get-RequiredProperty $mp $field
        $desired = $meetingBaseline[$field]
        if ($current -ne $desired) {
            $changeMeetingBaseline = $true
            $plan.Add("Meeting policy '$MeetingPolicyIdentity': $field -> $desired")
        }
    }
    Write-Warning "Restricted meeting baseline reduces meeting-path risk but is not an all-path collaboration deny rule. Guest identities, anonymous signed-out joins to other tenants, shared channels, and organizer-admitted lobby participants need separate governance."
}

$requiredCommands = @{ 'Set-CsExternalAccessPolicy' = @('Identity', 'EnableFederationAccess') }
if ($changeTenant -or $changeDomains) {
    $requiredCommands['Set-CsTenantFederationConfiguration'] = @('AllowFederatedUsers')
}
if ($changeDomains) {
    $requiredCommands['Set-CsTenantFederationConfiguration'] += 'AllowedDomains'
    $requiredCommands['New-CsEdgeDomainPattern'] = @('Domain')
    $requiredCommands['New-CsEdgeAllowList'] = @('AllowedDomain')
}
if ($groupOnly) {
    $policyCommand = if ($null -eq $managedPolicy) { 'New-CsExternalAccessPolicy' } else { 'Set-CsExternalAccessPolicy' }
    $requiredCommands[$policyCommand] = @('Identity', 'EnableFederationAccess', 'CommunicationWithExternalOrgs',
        'AllowedExternalDomains', 'EnableTeamsConsumerAccess', 'EnableTeamsConsumerInbound', 'EnableAcsFederationAccess')
    $requiredCommands['Grant-CsExternalAccessPolicy'] = @('Group', 'PolicyName', 'Rank')
}
if ($changeLobby -or $SetRestrictedMeetingBaseline) {
    $meetingPolicyParameters = @('Identity')
    if ($changeLobby) { $meetingPolicyParameters += 'AutoAdmittedUsers' }
    if ($SetRestrictedMeetingBaseline) { $meetingPolicyParameters += @($meetingBaseline.Keys) }
    $requiredCommands['Set-CsTeamsMeetingPolicy'] = @($meetingPolicyParameters | Select-Object -Unique)
}
foreach ($commandName in $requiredCommands.Keys) {
    $command = Get-Command $commandName -ErrorAction Stop
    foreach ($parameterName in $requiredCommands[$commandName]) {
        if (-not $command.Parameters.ContainsKey($parameterName)) {
            throw "$commandName does not support '$parameterName' in the installed module/cloud. No changes have been applied."
        }
    }
}

Write-Action Info "Proposed changes:"
foreach ($change in $plan) { Write-Action Report "  $change" }
foreach ($conflict in $conflicts) { Write-Action Error $conflict }
Write-Action Info "Federation requires reciprocal partner configuration and effective policies on both sides."
Write-Action Info "Entra inbound trust is not a universal Teams meeting-admission gate."

if ($ReportOnly -or $WhatIfPreference) {
    if ($WhatIfPreference -and $plan.Count) {
        $null = $PSCmdlet.ShouldProcess("Teams federation ($ExternalCollaborationScope)", ($plan -join '; '))
    }
    Write-Action Skipped "Preview only; no settings changed. Blocking conflicts: $($conflicts.Count)."
    return
}
if ($conflicts.Count) { throw "Safety inventory found $($conflicts.Count) blocking conflict(s). No changes have been applied." }
if ($plan.Count -eq 0) {
    Write-Action Found "Requested configuration is already present. Effective policies and propagation still require validation."
    return
}
if (-not $PSCmdlet.ShouldProcess("Teams federation ($ExternalCollaborationScope)", ($plan -join '; '))) {
    Write-Action Skipped "Changes declined; no settings changed."
    return
}
$answer = Read-Host "Apply the listed changes, including any changed federation restrictions? Type y to continue (anything else cancels)"
if ($answer -cne 'y') {
    Write-Action Skipped "Continuation not approved; no settings changed."
    return
}

if ($groupOnly) {
    if ($changePolicy) {
        $policyParameters = @{
            Identity = $managedPolicyName
            EnableFederationAccess = $true
            CommunicationWithExternalOrgs = 'AllowSpecificExternalDomains'
            AllowedExternalDomains = $targetDomains
            EnableTeamsConsumerAccess = $false
            EnableTeamsConsumerInbound = $false
            EnableAcsFederationAccess = $false
            ErrorAction = 'Stop'
        }
        if ($null -eq $managedPolicy) { New-CsExternalAccessPolicy @policyParameters | Out-Null }
        else { Set-CsExternalAccessPolicy @policyParameters }
        Write-Action Set "Configured '$managedPolicyName' for the specified partner domains."
    }
    if ($changeAssignment) {
        Grant-CsExternalAccessPolicy -Group $CollaborationGroupId.ToString() `
            -PolicyName $managedPolicyName -Rank $assignmentRank -ErrorAction Stop
        Write-Action Set "Assigned '$managedPolicyName' to group $CollaborationGroupId."
    }
}
# Restrict domains before enabling Global; group assignment must succeed before
# changing the Global default. Enable a disabled tenant master switch last.
if ($changeDomains) {
    $patterns = @($mergedDomains | ForEach-Object { New-CsEdgeDomainPattern -Domain $_ -ErrorAction Stop })
    $allowList = New-CsEdgeAllowList -AllowedDomain $patterns -ErrorAction Stop
    Set-CsTenantFederationConfiguration -AllowedDomains $allowList -ErrorAction Stop
    Write-Action Set "Updated tenant allowed domains; unrelated settings preserved."
}
if ($changeGlobal) {
    Set-CsExternalAccessPolicy -Identity Global -EnableFederationAccess $desiredGlobal -ErrorAction Stop
    Write-Action Set "Global EnableFederationAccess = $desiredGlobal"
}
if ($changeTenant) {
    Set-CsTenantFederationConfiguration -AllowFederatedUsers $true -ErrorAction Stop
    Write-Action Set "Enabled tenant federation; unrelated settings preserved."
}
if ($changeLobby) {
    Set-CsTeamsMeetingPolicy -Identity $MeetingPolicyIdentity `
        -AutoAdmittedUsers EveryoneInSameAndFederatedCompany -ErrorAction Stop
    Write-Action Set "Updated lobby bypass on '$MeetingPolicyIdentity'."
}
if ($changeMeetingBaseline) {
    $meetingParameters = @{ Identity = $MeetingPolicyIdentity; ErrorAction = 'Stop' }
    foreach ($field in $meetingBaseline.Keys) { $meetingParameters[$field] = $meetingBaseline[$field] }
    Set-CsTeamsMeetingPolicy @meetingParameters
    Write-Action Set "Updated restricted meeting baseline on '$MeetingPolicyIdentity'."
}
Write-Action Info "Configuration applied. Changes are not transactional; failures stop without rollback. Policy/group propagation is asynchronous; validate effective assignments and documented communication-path gaps."
