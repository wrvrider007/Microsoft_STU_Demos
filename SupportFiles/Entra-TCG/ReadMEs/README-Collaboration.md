# collaboration.json — Cross-Tenant Community Collaboration

## Overview

`collaboration.json` is a declarative template applied by `Apply-GraphTemplate.ps1`
(documented in **README-Engine.md**). It establishes a multi-tenant collaboration fabric
across community Microsoft Entra tenants without relying on Microsoft 365 Multi-Tenant
Organization (MTO). The template configures administrator-gated B2B collaboration,
per-partner cross-tenant trust, dynamic and static group structures, an access-package
entitlement gate, and a staged outbound cross-tenant synchronization configuration.
SharePoint Online and OneDrive sharing are configured separately with
`Configure-SharePointSharing.ps1` because those tenant settings live in SPO PowerShell,
not Microsoft Graph.

For the Teams control landscape, group-scoped federation, meeting gates, and known
enforcement gaps, see [Teams Collaboration Gates](README-Teams-Collaboration-Gates.md).
That assessment separates required baseline controls, optional recommendations, and
known gaps for `Configure-TeamsCollaboration.ps1`.

The template is idempotent: it may be applied repeatedly, and each run reconciles the
tenant to the declared desired state.

## Invocation

```powershell
# Read-only preview, resolving a partner tenant from its domain:
.\Apply-GraphTemplate.ps1 -TemplatePath .\collaboration.json -Domain fabrikam.com -WhatIf

# Apply for one or more partner tenants:
.\Apply-GraphTemplate.ps1 -TemplatePath .\collaboration.json -Domain fabrikam.com,contoso.com

# Configure staged CTS job display-name mappings before starting sync:
.\Configure-CommunitySyncMappings.ps1 -Domain fabrikam.com,contoso.com -OrgLabel FAB -WhatIf
.\Configure-CommunitySyncMappings.ps1 -Domain fabrikam.com,contoso.com -OrgLabel FAB

# Configure SharePoint/OneDrive sharing to match the collaboration baseline:
.\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com -WhatIf
.\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com
```

The `-Domain` and `-TenantId` parameters define the **partner tenants**. Resources marked
*forEach* are applied once per partner.

## Design principles

The template implements the following model:

- **Requestors are internal users.** Internal users request the access package in their
  home tenant. Membership in the gate group scopes them into the outbound cross-tenant
  synchronization job, which provisions them into partner tenants as members rather than
  guests. Access packages therefore govern which internal users synchronize outward, not
  which external users request inward.
- **Inbound collaboration and shared-channel defaults are denied by default; partners
  form an allow-list.** Only the partner tenants explicitly configured by the template
  may collaborate inbound through B2B collaboration. Default B2B direct connect is
  blocked inbound and outbound so shared channels require a separate opt-in design.
  Outbound B2B collaboration remains open by default; blocking it is recommended only
  after exception review.
- **Trust and automatic consent are configured per partner.** Multifactor claims are
  honored per partner, and the guest redemption prompt is suppressed per partner rather
  than globally. Compliant-device and hybrid-join trust are optional and are not
  configured by the initial baseline template.
- **The script manages only the objects it creates.** Pre-existing synchronization
  applications are detected and left unmodified; the script neither duplicates nor alters
  configuration it does not own.

## Required Microsoft Graph permissions

These are the **delegated** scopes (`graphScopes.delegated`), used for interactive sign-in:

```
Policy.ReadWrite.Authorization      Group.ReadWrite.All
Policy.Read.All                     EntitlementManagement.ReadWrite.All
Policy.ReadWrite.CrossTenantAccess  Application.ReadWrite.All
Synchronization.ReadWrite.All       AuditLog.Read.All
```

For app-only execution via `-AccessToken` (service principal or managed identity), the template's
`graphScopes.application` set is used. For this template the application app roles are identical
in name to the delegated scopes above. `Scripts/Initialize-TcgDeployerApp.ps1` grants them automatically.

Delegated execution additionally requires appropriate Microsoft Entra directory roles
(Global Administrator, or the combination of Identity Governance Administrator, Hybrid
Identity Administrator, Cloud Application Administrator, Security Administrator, and
Privileged Role Administrator — the last is required to update the authorization policy).
Microsoft Entra ID P1 or P2 licensing is required, as cross-tenant synchronization is a
licensed capability.

## Applied configuration

Resources are applied in template order. The tables below describe each resource and the
action the script performs.

### Tenant policy

| # | Resource | Action |
|---|---|---|
| 1 | Authorization policy (invites) | *Configure.* Restricts guest invitation to administrators and guest inviters and disables email-verified users joining the organization. Applied as an idempotent PATCH. |
| 2 | B2B invitation domain restrictions (precondition) | *Assert.* A read-only evaluation. If the tenant restricts B2B invitations to a domain allow-list that would exclude community tenants, the script emits a warning and continues. The policy is never modified. |

### Cross-tenant access

| # | Resource | Action |
|---|---|---|
| 3 | Cross-tenant access — partner *(forEach)* | *Create and configure.* Creates the partner configuration keyed by tenant ID if absent, then configures MFA inbound trust, automatic user consent, and inbound and outbound B2B collaboration as allowed. |
| 4 | Cross-tenant access — default | *Configure.* Sets the tenant default for inbound B2B collaboration to blocked, blocks default inbound/outbound B2B direct connect, and keeps default inbound trust disabled. |

### Groups

Dynamic groups are governed by membership rules; the static sync gate is populated by
the access package, while administrators maintain the block group and NOFORN
eligibility group. The token `#EXT#` in a user principal name identifies an external
user (synchronized or invited). `NOFORN - Internal` may be assigned or dynamic, but
dynamic membership must use an approved authoritative eligibility signal, such as a
dedicated extension/custom security attribute or HR-fed field. Do not rely on generic
profile `country` or `usageLocation` unless the customer explicitly approves that
attribute as authoritative for NOFORN eligibility.

| # | Group display name | Type | Membership definition and purpose |
|---|---|---|---|
| 5 | External Community Members | Dynamic | `userType = Member` and UPN contains `#EXT#`. Users synchronized into the tenant via cross-tenant synchronization. |
| 6 | External Users All | Dynamic | UPN contains `#EXT#`. All external users (synchronized or invited). Provisioned by collaboration; hardening no longer creates this unused dependency. |
| 7 | Organization Internal Only | Dynamic | `userType = Member` and UPN does not contain `#EXT#`. Internal tenant members. |
| 8 | NOFORN - Internal | Assigned or governed dynamic | Governed internal users eligible to request NOFORN community collaboration. Captured as `noforInternal`; used as the requestor scope of the assignment policy (resource 16). The template-created default is assigned/static because the template cannot safely invent a tenant-specific eligibility attribute. |
| 9 | NOFORN Internal eligibility source | Assert | Warns if an existing **NOFORN - Internal** group is dynamic membership so administrators can confirm the rule uses an approved authoritative eligibility signal. |
| 10 | External Collaboration Blocked | Static | Non-mail-enabled security group with administrator-managed membership. Captured as `collaborationBlocked`; members cannot request the Community Collaboration - All access package. |
| 11 | Community Collab Sync - All | Static | The outbound synchronization gate. Captured as `group`. Members are provisioned outward to partner tenants. Serves as both the access-package target and the scope of the cross-tenant synchronization jobs. |

### Entitlement management

| # | Resource | Action |
|---|---|---|
| 12 | Catalog — Community Collaboration | *Create.* The access package catalog. Captured as `catalog`. |
| 13 | Catalog resource — add All group | *Create.* Adds group 11 to the catalog as a resource. Applied with retry-and-backoff to accommodate directory replication latency. |
| 14 | Access package — Community Collaboration - All | *Create with role scope.* Creates the access package, then attaches the group's Member role scope after polling for the catalog resource to become available. Captured as `accessPackage`. |
| 15 | Access package incompatible group — External Collaboration Blocked | *Create if missing.* Adds the block group to the access package's `incompatibleGroups` using a Graph v1.0 reference. Preserves other incompatible groups; retries creation for replication latency. |
| 16 | Policy — Community Collaboration - All (no approval) | *Create.* An assignment policy scoped to the **NOFORN - Internal** group's members (`specificDirectoryUsers`), permitting self-service request without approval, subject to the access package's incompatible-group restriction. |

Add users to **External Collaboration Blocked** to prevent them requesting the package that grants
membership in **Community Collab Sync - All**. This separation-of-duties check is an access-package
gate, not a general group-membership deny rule: it does not prevent direct group additions or
automatically revoke existing package assignments or sync-gate membership. Handle existing access
separately when blocking a user who is already collaborating.

Before go-live, define assignment expiration and recurring access reviews for the
access package, or document a mission-approved permanent-access exception. The template
does not hard-code a universal duration or review cadence.

### Cross-tenant synchronization (staged)

These resources are applied once per partner. They configure, but do not start, outbound
provisioning.

| # | Resource | Action |
|---|---|---|
| 17 | Sync inbound-allow | *Configure (PUT).* Enables inbound user synchronization for the partner. If already enabled, the resulting conflict is reported as skipped. |
| 18 | Sync app | *Create with guard.* Instantiates the cross-tenant synchronization gallery application named `CTS - <Partner>`. If a synchronization application with a different name already exists, the guard emits a warning and skips creation. Captures the service principal identifier and the `msiam_access` application role identifier. |
| 19 | Sync job | *Create.* Creates the `Azure2Azure` provisioning job on the service principal. Requires the captured service principal identifier. |
| 20 | Sync secrets | *Configure (PUT).* Saves the credentials `CompanyId = <partner tenant ID>` and `AuthenticationType = SyncPolicy`, which bind the application to its target tenant. Requires the captured service principal identifier. |
| 21 | Sync scope | *Create.* Assigns group 11 to the service principal's `msiam_access` role so that its members are provisioned outward. Existence is evaluated client-side because the `appRoleAssignedTo` endpoint does not support `$filter`. Requires the captured service principal identifier. |

## Operational considerations

### Teams trusted domains are additive

`Configure-TeamsCollaboration.ps1` configures organizational federation with the
MicrosoftTeams PowerShell module. `-ExternalCollaborationScope` selects the model:

| Scope | Configuration |
|---|---|
| `Global` (default) | Enables federation in the Global external access policy and tenant master switch; merges supplied domains into the tenant allowed list, preserving existing explicit allowed domains. Custom policies and assignments are preserved, not overridden. |
| `CollaborationGroupOnly` | Disables federation in the Global external access policy; creates/updates `TCG-CommunityCollaboration-<group-object-id>` with exactly the supplied domains and assigns it to the selected group. Enables the tenant master switch without changing tenant domain lists. |

Group scope **requires `-CollaborationGroupId`**, the object ID of the existing
**Community Collab Sync - All** security group. **Community Collaboration - All**
is the access package, not the group's display name. Copy the security group's
object ID from the Entra admin center; do not supply the access-package ID.
The Teams-only helper does not add a Graph dependency or resolve display names.
The service validates the group assignment before the helper changes the Global
policy or tenant master switch.

```powershell
.\Configure-TeamsCollaboration.ps1 -Domains fabrikam.com -ExternalCollaborationScope Global -WhatIf

.\Configure-TeamsCollaboration.ps1 -Domains fabrikam.com `
    -ExternalCollaborationScope CollaborationGroupOnly `
    -CollaborationGroupId '<Community Collab Sync - All object ID>' `
    -SetRestrictedMeetingBaseline -ReportOnly
```

Every run inventories external access policies, group assignments/ranks, and each
Teams user's direct/group policy sources, plus tenant federation and the selected
meeting policy. This can take time in large tenants. Read failures, unknown assignment
sources, or inconsistent propagation stop the run before mutation. `-ReportOnly` and
`-WhatIf` preview without changing settings or requesting continuation consent.
Applying changes requires an explicit lowercase `y`, even with `-Confirm:$false`.
No prompt is shown when the requested configuration is already present.

Global warns when custom policies exist: **Global does not override direct or
group-assigned policies**, although enabling tenant federation can reactivate them.
An allow-all tenant default is converted to an explicit list only after the change
preview and consent. Existing blocked domains are not deleted, but Teams ignores
the tenant blocked list when an explicit tenant allowed list is used. Requested
domains covered by an existing tenant block are refused until manually reconciled.

Group-only mode refuses federation-capable direct user assignments and assignments
to other groups, including use of this helper's policy outside the selected group.
Without Graph membership inspection, this guard is deliberately conservative:
even direct assignments to eligible members must be reconciled manually.
Other policies and assignments are never automatically removed or disabled.
The selected group's existing rank is preserved; a new assignment is appended
after existing ranks so unrelated rankings are not shifted. Restrictive direct
policies or higher-ranked group policies can still prevent selected members
from federating. Only direct group members inherit the assignment.
The managed policy disables unmanaged consumer and ACS access; it is reserved
for this helper and its domain list is replaced, not merged, on approved updates.

Neither scope is an all-Teams communication boundary. Group-chat participant gaps,
guest identities, shared channels, anonymous joining, and meeting chat need separate
controls. Optional `-SetRestrictedMeetingBaseline` configures the named meeting
policy with the required collaboration defaults:

- `ExternalMeetingJoin = EnabledForTrustedOrgs`
- `MeetingChatEnabledType = EnabledInMeetingOnlyForAllExceptAnonymous`
- `AllowExternalNonTrustedMeetingChat = False`
- `AllowAnonymousUsersToStartMeeting = False`
- `AllowPSTNUsersToBypassLobby = False`
- `UsersCanAdmitFromLobby = OrganizerAndCoOrganizersOnly`

Optional `-SetLobbyBypassForFederated` remains
independent of group scope and applies to the named meeting policy, not just
collaboration-group attendees. Entra inbound trust alone does not establish
authenticated meeting admission.
Changes are not transactional: a failure stops without automatic rollback; review
the reported completed steps before retrying. Validate target-cloud support,
effective policies, reciprocal partner configuration, and asynchronous propagation
using the [Teams Collaboration Gates assessment](README-Teams-Collaboration-Gates.md).

### Synchronized display names identify file-sharing objects

`Configure-CommunitySyncMappings.ps1` updates the staged cross-tenant synchronization
job's `displayName` attribute mapping before synchronization starts. The mapping appends
an optional organization label and a sharing suffix so users can distinguish local synced
resource-access objects from Teams federated chat contacts.

For example:

```powershell
.\Configure-CommunitySyncMappings.ps1 -Domain fabrikam.com -OrgLabel FAB
```

With the default `-SharingSuffix "File Sharing Only"`, a source display name of
`Masse, Andrew` becomes `Masse, Andrew [FAB] - File Sharing Only`. If `-OrgLabel` is
omitted, the result is `Masse, Andrew - File Sharing Only`.

The script accounts for the Microsoft Entra `displayName` maximum length of 256
characters by truncating the source display name before appending the label and suffix.

### Synchronization is configured but not started

The template provisions the outbound synchronization application, job, secrets, and scope,
but does not start provisioning. Starting synchronization has a cross-tenant prerequisite:
the partner tenant must have enabled inbound synchronization for this tenant by applying
its own configuration. Provisioning should be started as a separate operation once both
tenants have completed their configuration. Run `Configure-CommunitySyncMappings.ps1`
before starting the job in the portal or with `Start-CommunitySync.ps1`.

### SharePoint and OneDrive sharing companion script

`Configure-SharePointSharing.ps1` configures the SharePoint admin center
organization-level sharing baseline through `Set-SPOTenant`:

| Setting | Value |
|---|---|
| SharePoint external sharing | Existing guests (`ExistingExternalUserSharingOnly`) |
| OneDrive external sharing | Existing guests (`ExistingExternalUserSharingOnly`) |
| Default file/folder link | Only people in your organization (`Organization` / legacy `Internal`) |
| Default sharing-link permission | View |

The script uses the newer SharePoint/OneDrive-specific tenant parameters when the
installed SPO module exposes them, and falls back to the legacy combined parameters
when needed. The SharePoint admin center also shows viewer-name and short-link
checkboxes; the script prints those as manual verification items because the current
public `Set-SPOTenant` reference does not expose stable parameters for them.
It does not set **Limit external sharing by domain** because a tenant-wide allow-list
is intentionally tighter than the collaboration baseline. If domain restriction is
already configured, the script reports it and warns that any allow-list must include
all community tenant domains.

This script does not use `clouds.json`; that file is for Microsoft Graph and Azure CLI
endpoint resolution. For sovereign tenants, pass the SharePoint admin center URL in
that cloud to `-AdminUrl`. For GCC High and DoD, pass `-Region ITAR` if required by
`Connect-SPOService`. RX/EX region values are intentionally not mapped yet; validate
the required SPO `-Region` value in the airgap cloud before adding guidance.

### Synchronization application identity

A cross-tenant synchronization application's target tenant is stored only in the
write-only `CompanyId` secret and cannot be read back through Microsoft Graph.
Consequently, the `CTS - <Partner>` display-name convention is the sole durable, readable
handle that associates an application with a partner, and it must be preserved. An existing
application with a non-conforming name is intentionally not adopted; to bring such an
application under management, rename it to `CTS - <Partner>` and re-apply the template.

### Ordering of the default block and partner allow entries

On a newly provisioned tenant, applying the default inbound block presents no risk. On a
tenant with existing inbound collaboration, partner allow entries should exist before the
default is set to blocked, so that no active partner relationship is interrupted. The
template orders partner configuration (resource 3) before the default (resource 4)
accordingly.

### Resource ordering and captured values

Resources that produce captured values (`noforInternal`, `collaborationBlocked`, `group`, `catalog`, and
`accessPackage`) are declared before the resources that consume them, so that token
references resolve at apply time. New resources must be placed in dependency order.

## Idempotency and re-execution

The template may be applied repeatedly. Each run reports its actions:

- **Created** or **Found** — a new object was created, or an existing object was detected
  and left unchanged.
- **Applied** — a configure or role-scope operation re-asserted the desired state,
  independent of whether a change occurred.
- **Skipped** — no action was required, a prerequisite was unavailable, or a conflict
  indicated the desired state already existed.
- **Warning** — a precondition or guard was triggered, such as a restrictive B2B domain
  policy or an existing unmanaged synchronization application.

A read-only preview is available with `-WhatIf`; `-Verbose` additionally reports each
Microsoft Graph request.
