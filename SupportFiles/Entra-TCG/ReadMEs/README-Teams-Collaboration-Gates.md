# Teams Collaboration Gates

## Purpose and status

This reference captures the **art of the possible** for restricting Microsoft Teams
collaboration between community tenants. It separates available controls, policy scope,
enforcement gaps, and decisions that must precede changes to
[`Configure-TeamsCollaboration.ps1`](../Scripts/Configure-TeamsCollaboration.ps1).

**Research baseline: October 2, 2026.** This is a capability assessment, not an approved
enforcement baseline or a claim that every feature is available in every cloud. Examples
are illustrative, change tenant/user policy, and must not be run without reviewing the
existing configuration and intended impact.

Related references:
[collaboration template](README-Collaboration.md),
[hardening template](README-Hardening.md), and
[Cloud Shell deployment](CloudShellDeployment.md).

## The central distinction

**Teams supports group-assigned external-access policies with their own allowed/blocked
domain lists.** This enables a configuration such as:

> Only members of security group G in tenant A may federate with the specified domains
> used by tenant B.

That is **not equivalent** to:

> No user outside G can ever communicate with anyone from B through any Teams chat,
> meeting, guest identity, shared channel, or anonymous session.

The broader requirement crosses several independent identity and communication paths.
External group chats also have documented participant-enforcement limitations. Define
the required boundary before selecting controls.

## Collaboration paths and their gates

| Path | Principal gates | Boundary or limitation |
|---|---|---|
| Organizational federated 1:1 chat and calls | Tenant federation switch, effective external-access policy, partner's reciprocal federation settings | Domain-based, not a partner-tenant GUID rule. |
| Federated group chats | External-access policy plus chat initiation/roster behavior | Current documentation does not guarantee mutual authorization between every pair of participants. |
| External people using B2B accounts in the resource tenant | Teams guest access where applicable, Entra B2B settings, directory/resource membership, Conditional Access | Not ordinary federation. Cross-tenant-synchronized external accounts can have `userType = Member`; that does not make them home-tenant identities. |
| Unmanaged Teams/Microsoft accounts | Separate tenant and user-policy consumer-access switches | Not covered by an organization's federation-domain list. |
| Shared channels | Bilateral Entra B2B direct connect, channel membership, Teams channels policies | Separate path; supports tenant-ID and user/group scoping in Entra. |
| External people joining A-hosted meetings | Organizer's federation eligibility, guest identity path, anonymous/verified joining, lobby/admission | Lobby placement is not a permanent join prohibition. |
| A users joining B-hosted meetings | Participant's `ExternalMeetingJoin` policy, identity used to join, managed-device/network controls | Guest, signed-out anonymous, and shared-channel paths have exceptions. |
| Meeting chat | Meeting-chat policy, organizer options, external nontrusted-meeting-chat control | Does not follow ordinary federated-chat rules identically. |
| Recordings, transcripts, and shared files | Meeting options plus SharePoint/OneDrive and applicable Purview controls | Permission to participate does not define all content-access rights. |

Sources: [external versus guest access][external-guest], [external meeting
participants][meeting-identities], and [shared channels][shared-channels].

## 1. Organizational federation: users, groups, and domains

### Available controls

| Scope | Cmdlet | Important parameters |
|---|---|---|
| Tenant federation configuration | `Set-CsTenantFederationConfiguration` | `AllowFederatedUsers`, `AllowedDomains`, `BlockedDomains`, `BlockAllSubdomains` |
| External-access policy | `New-CsExternalAccessPolicy` / `Set-CsExternalAccessPolicy` | `EnableFederationAccess`, `CommunicationWithExternalOrgs`, `AllowedExternalDomains`, `BlockedExternalDomains` |
| Policy assignment to a security group | `Grant-CsExternalAccessPolicy` | `Group`, `PolicyName`, `Rank` |

The policy parameters are **`AllowedExternalDomains` / `BlockedExternalDomains`**.
Do not confuse them with the tenant configuration's `AllowedDomains` / `BlockedDomains`.

`CommunicationWithExternalOrgs` supports `OrganizationDefault`,
`AllowAllExternalDomains`, `AllowSpecificExternalDomains`,
`BlockSpecificExternalDomains`, and `BlockAllExternalDomains`.

Custom policies support up to **100 domains** in an allowed or blocked list; tenant
lists support up to **4,000 domains**. The Global policy's domain mode remains
`OrganizationDefault`; configure its default domains through tenant federation settings.

### Precedence and reciprocal setup

**Custom policy domain rules can override the organization's domain list.** The two
lists are not simply an intersection, and the tenant domain list is not an absolute
ceiling for all custom policies.

However, tenant `AllowFederatedUsers = $false` is a **master disable** that overrides
external-access policy instances. It must be enabled for selective federation to work.

B must also permit federation with A, and the relevant users on both sides must have
effective policies that permit the intended communication. If only approved B users
should participate, B must implement its own user/group policy scoping.

Sources: [granular external-access configuration][granular],
[external-access policy reference][external-policy], and
[tenant federation reference][tenant-federation].

### Example: approved group only, specific partner domains

This pattern assumes that users outside G should have **no organizational federation**.
It intentionally changes the Global default; inventory direct and group-assigned
exceptions before applying it.

```powershell
# Illustrative configuration, not the project's selected baseline.
Set-CsTenantFederationConfiguration -AllowFederatedUsers $true
Set-CsExternalAccessPolicy -Identity Global -EnableFederationAccess $false

New-CsExternalAccessPolicy `
    -Identity "Approved-Collaboration-With-B" `
    -EnableFederationAccess $true `
    -CommunicationWithExternalOrgs AllowSpecificExternalDomains `
    -AllowedExternalDomains @("b.example", "b-other.example")

Grant-CsExternalAccessPolicy `
    -Group "<approved-security-group-object-id>" `
    -PolicyName "Approved-Collaboration-With-B" `
    -Rank 1
```

If other A users should retain federation with other partners but not B, use a baseline
that excludes B and a custom policy that permits B for G. Preserve existing restrictions
and explicitly choose whether G may also reach other partners. Do not blindly replace
the tenant's allowed/blocked lists.

### Group policy assignment is selection, not policy merging

For each policy type, a **direct user assignment wins**. Otherwise, the highest-ranking
group assignment wins, with rank 1 highest. Otherwise, Global applies.

Policies do not merge, and a restrictive policy does not automatically win. Assigning a
deny policy to a block group is insufficient unless effective policy selection actually
chooses that policy for every affected user.

Only direct group members inherit assignments; nested membership does not. Hidden
membership groups are unsupported. Changes propagate asynchronously, so removal from
G is not an instantaneous revocation guarantee.

Inspect the effective assignment rather than only the group's configured policy:

```powershell
Get-CsUserPolicyAssignment `
    -Identity "user@a.example" `
    -PolicyType ExternalAccessPolicy
```

Source: [policy assignment and group precedence][policy-assignment].

### Domains are not tenant identifiers

Inventory B's relevant identity/SIP domains, additional domains, and subdomains.
Do not assume one verified domain automatically covers every alias or domain in B.
Blocking a parent domain does not block its subdomains by default; tenant
`BlockAllSubdomains` controls that behavior. Equivalent granular-policy behavior and
alias resolution require target-tenant testing.

The Cs* cmdlets' `Tenant` parameter selects the tenant being administered; it is not a
partner-tenant allowlist.

## 2. External group-chat enforcement gaps

The current tenant federation reference describes the following controls but explicitly
marks **both as reserved for future use, having no effect, and not to be used**:

| Parameter | Documented default behavior / proposed enforcement |
|---|---|
| `EnableExternalAccessRestrictionsForChatParticipants` | The described default allows a federation-disabled local user to be added to an external group chat by a federation-enabled local initiator. The proposed stricter behavior would prevent additions/remove affected users, but is not currently effective. |
| `EnableMutualFederationForChatParticipants` | Default enforcement checks federation between the initiator and an added participant, not every pair in the chat. The proposed stricter behavior would enforce mutual federation across the roster, but is not currently effective. |

These switches do not cover meetings or meeting chats. Do not use their presence in
PowerShell syntax as evidence that participant-level enforcement exists.

`FederatedBilateralChats = $true` is different: it restricts external group chats to
two organizations. It does not select a specific partner, restrict local participants
to G, or cover meetings, meeting chats, and channels.
Use it as a recommended reduction for multi-organization group-chat exposure, not as a
required collaboration boundary.

**A successful 1:1 test is not proof of an all-chat boundary.** Test initiators,
subsequent additions, existing rosters, and third-tenant participation explicitly.

Sources: [tenant federation parameter warnings][tenant-federation] and
[`FederatedBilateralChats`][external-policy].

## 3. Alternate chat and channel paths

### B2B identities and guest chat

B users using guest identities in A are not using the same path as B users federating
from their home identities. Federation-domain restrictions do not remove their accounts
or resource memberships. Cross-tenant-synchronized B2B accounts must also be assessed
according to their actual sign-in/resource-tenant context, not just their `userType`.

`Set-CsTeamsGuestMessagingConfiguration -AllowUserChat $false` is a broad organization
guest-chat control, not a per-partner/per-local-group mapping. Govern invitations,
accounts, resource membership, and Entra cross-tenant access separately.

For this TCG, Teams guest access is a required governance decision before go-live:
inventory existing guests and team memberships, decide whether the guest/member
alternate path is allowed, limited, or blocked, and reconcile existing grants. Do not
blindly disable tenant-wide guest access without workload review, but do not leave it
as an unreviewed path around CTS and federation.

Sources: [external versus guest access][external-guest],
[guest messaging configuration][guest-messaging], and
[Entra cross-tenant access][cross-tenant].

### Unmanaged accounts

Assess tenant `AllowTeamsConsumer` / `AllowTeamsConsumerInbound` and policy
`EnableTeamsConsumerAccess` / `EnableTeamsConsumerInbound` separately. Organizational
federation-domain lists do not define this identity class.

Microsoft documents unmanaged Teams external access as unavailable in GCC, GCC High,
DoD, and private-cloud deployments. Skype consumer interoperability ended May 5, 2025;
stale Skype-related cmdlet text is not evidence of a current collaboration path.

Source: [external-access identity types][external-guest].

### Shared channels / Teams Connect

`CsTeamsChannelsPolicy` includes `AllowSharedChannelCreation`,
`AllowChannelSharingToExternalUser`, and `AllowUserToParticipateInExternalSharedChannel`.
Entra B2B direct connect is a bilateral, tenant-ID-based relationship that can be scoped
to users/groups and applications. Selected-user/group scoping requires Entra ID P1 on
the configuring tenant.

Disabling external channel sharing does not revoke access already granted. Inventory
existing channel membership and channel meetings separately.

The Entra collaboration template blocks default inbound and outbound B2B direct connect.
Shared channels therefore require a separate opt-in design with partner, user/group,
application, lifecycle, and content-governance decisions.

Sources: [shared channels][shared-channels],
[channel policy parameters][channel-policy], and
[B2B direct connect scoping][direct-connect].

### Broad chat disablement

Teams messaging policy `AllowUserChat` can disable new 1:1 and group chats broadly.
It is not a selective external-partner control and also affects internal collaboration.
`AllowChatWithGroup` concerns starting chats with directory groups; it is not the missing
mutual-federation enforcement switch for ordinary multi-person chats.

Source: [messaging policies][messaging-policy].

## 4. Inbound meetings: B users joining meetings organized in A

### Identity classification and actual admission gates

External participants may arrive as guests, trusted organizational users, or
anonymous/unverified users. Mutual federation and effective user policies affect trusted
classification. A blocked/nonmutual organization may still participate anonymously if
the organizer's anonymous-join policy permits it.

An organizer without federation permission does not automatically exclude external
attendees: alternate guest and anonymous identity paths must also be addressed.

| Control | Purpose | Limitation |
|---|---|---|
| `AllowAnonymousUsersToJoinMeeting` | Allows/disallows unverified anonymous joining for the organizer's meetings | Evaluate the separate verified-anonymous option as well. |
| `AnonymousUserAuthenticationMethod` | `OneTimePasscode` or `None` for the email-code verification path | Email ownership is not verified membership of tenant B or group G. |
| `AutoAdmittedUsers` | Sets who bypasses the lobby | Those who do not bypass may still be admitted. |
| `UsersCanAdmitFromLobby` | Determines who may admit waiting participants | Admission authority can allow external people in. |
| Meeting templates / sensitivity labels | Enforce supported meeting options | Licensing and supported lockable settings apply. |
| `AllowPSTNUsersToBypassLobby` | Controls lobby bypass for dial-in participants | Not a verified tenant/group identity gate or a prohibition on dial-in joining. |

For restricted organizers, evaluate both anonymous policy settings:

```powershell
# Illustrative: a pre-existing meeting policy, not a deployment command.
Set-CsTeamsMeetingPolicy -Identity "RestrictedOrganizers" `
    -AllowAnonymousUsersToJoinMeeting $false `
    -AnonymousUserAuthenticationMethod None
```

The required restricted collaboration meeting baseline also disables anonymous meeting
start and PSTN lobby bypass:

```powershell
Set-CsTeamsMeetingPolicy -Identity "RestrictedOrganizers" `
    -AllowAnonymousUsersToStartMeeting $false `
    -AllowPSTNUsersToBypassLobby $false
```

Email-code verification requires a Teams Premium organizer and does not establish a
trusted Entra organizational identity. Invitations do not override disabled anonymous
joining. When anonymous joining is enabled, invited participants from blocked
organizations can still benefit from invitation-based lobby behavior.

The legacy organization-wide `DisableAnonymousJoin` setting is being retired according
to Microsoft; use organizer-policy design rather than building a new baseline around it.

Sources: [meeting participant identities][meeting-identities],
[anonymous and email-verified joining][anonymous-meetings], and
[meeting-policy parameters][meeting-policy].

### Lobby controls are not collaboration deny rules

`AutoAdmittedUsers` supports:

| Value | Who may bypass |
|---|---|
| `Everyone` | Everyone |
| `EveryoneInSameAndFederatedCompany` | Organization, guests, and trusted organizations |
| `EveryoneInCompany` | Organization and guests |
| `EveryoneInCompanyExcludingGuests` | Organization members |
| `InvitedUsers` | Invited participants |
| `OrganizerOnly` | Organizers/co-organizers |

Meeting policies generally set lobby defaults that organizers can change. Teams Premium
templates or sensitivity labels can lock supported settings, but Microsoft documents
that templates/labels cannot lock **who can admit from the lobby**.

For restricted collaboration meeting policies, narrow `UsersCanAdmitFromLobby` to
`OrganizerAndCoOrganizersOnly` where supported. This reduces admission risk but remains
a lobby-default control, not a hard partner/group authorization boundary.

An organizer-only lobby means "wait for admission," not "external people cannot join."
Assigning a policy to G controls whose meetings use that policy; it does not ensure that
only G members from A attend a permitted organizer's meeting containing B.

Sources: [lobby behavior and enforcement][lobby] and
[templates, labels, and policy precedence][meeting-labels].

## 5. Outbound meetings: A users joining meetings organized in B

The effective documented participant-side setting is `ExternalMeetingJoin`:

| Value | Scope |
|---|---|
| `EnabledForAnyone` | External meetings allowed; default |
| `EnabledForTrustedOrgs` | Internal meetings and meetings hosted by trusted organizations |
| `Disabled` | Internal meetings only |

Assign meeting policies to the intended users/groups separately from organizer-side
admission policies. There is no external-partner domain list inside this setting;
the trusted-organization relationship matters.

The required baseline for governed users is `EnabledForTrustedOrgs`. Do not use
`Disabled` as the default partner-collaboration baseline because it blocks legitimate
partner-hosted meetings.

**Documented exceptions:** it does not block signed-out anonymous joining, joining
through a guest identity in the external tenant, or external shared-channel meetings.
The documented scope is meetings, not events.

The older `AllowUserToJoinExternalMeeting` parameter is documented as having no effect.
Do not substitute it for `ExternalMeetingJoin`.

Sources: [external meeting join restrictions][external-meeting-join] and
[meeting-policy reference][meeting-policy].

## 6. Meeting chat is a separate gate

For A-hosted meetings, `MeetingChatEnabledType` includes `Enabled`,
`EnabledExceptAnonymous`, `Disabled`, `EnabledInMeetingOnlyForAll`, and
`EnabledInMeetingOnlyForAllExceptAnonymous`.

`EnabledExceptAnonymous` blocks anonymous participants from reading/sending meeting
chat; it does not exclude trusted B participants or guests. `Disabled` disables meeting
chat and organizers cannot enable it again. The policy has per-user and per-organizer
behavior; it does not apply to channel meetings.

The required baseline for restricted collaboration meetings is
`EnabledInMeetingOnlyForAllExceptAnonymous`: trusted participants can chat during the
meeting, anonymous participants are excluded, and post-meeting chat persistence is
reduced by default.

For A users in externally hosted meetings, `AllowExternalNonTrustedMeetingChat = $false`
restricts reading/sending chat when the hosting organization is **not trusted**.
It is not a "no chat in every external meeting" toggle and does not independently deny
chat with a particular trusted partner.
This setting is required for governed users.

Lobby-chat documentation has rollout inconsistencies: the cmdlet reference discusses
also disabling `LobbyChat` while marking it unreleased, whereas conceptual documentation
describes lobby chat. Verify target-service behavior before claiming that disabling
meeting chat closes every lobby interaction.

`DisableAppInteractionForAnonymousUsers` controls interaction with meeting **apps**,
not joining or ordinary meeting chat.

Sources: [meeting chat controls][meeting-chat],
[meeting-policy reference][meeting-policy], and
[meeting configuration reference][meeting-configuration].

## 7. Entra, device/network, and Purview layers

| Layer | Useful gate | Do not mistake it for |
|---|---|---|
| Entra cross-tenant access | Tenant/user/group/application controls for B2B collaboration and B2B direct connect | A replacement for Teams federation-domain policies. |
| Conditional Access and inbound trust | Sign-in/resource-access requirements, MFA/device requirements, and acceptance of external claims in supported B2B paths | A per-recipient federation rule or a meeting-admission allowlist. |
| Tenant restrictions v2 | Controls external-account/resource access from managed devices/networks; can address alternate-account/anonymous paths in supported deployments | A guarantee on unmanaged personal devices, or anonymous protection from proxy-only authentication headers. |
| Information Barriers | Segmentation inside the directory, including supported guest scenarios | Arbitrary cross-tenant federation segmentation; IB groups cannot be created across tenants. |
| DLP | Restricts sensitive message/file content | A participant admission boundary. Federated-chat coverage depends on the hosting/initiating tenant. |

Tenant restrictions v2 authentication-plane protection is GA, while Teams/data-plane/
Windows scenarios are documented as preview. Deployment mechanism matters: proxy header
injection, Windows enforcement, and Global Secure Access do not have identical coverage.
Entra ID P1/P2 licensing applies.

Information Barriers in shared channels govern the host organization's users; they do
not simply follow a user into another organization's channel. Teams message DLP requires
appropriate E5/equivalent/add-on licensing.

`ConditionalAccessAttendeeVerification` appears in the meeting-policy reference but is
explicitly documented as not fully released and having no effect. Do not use it as a
currently available meeting boundary.

Sources: [cross-tenant access][cross-tenant], [tenant restrictions v2][tenant-restrictions],
[Information Barriers in Teams][information-barriers], [Teams DLP][teams-dlp], and
[meeting-policy reference][meeting-policy].

## 8. Current Entra-TCG helper scope and gaps

The current [`Configure-TeamsCollaboration.ps1`](../Scripts/Configure-TeamsCollaboration.ps1):

| Surface | Current behavior | Not implemented |
|---|---|---|
| Global external-access policy | `Global` scope enables federation; `CollaborationGroupOnly` disables it and assigns a domain-specific custom policy to the supplied group ID | Automatic removal/reconciliation of unrelated direct or group policy exceptions. |
| Tenant federation | Enables the master switch; `Global` merges explicit allowed domains, while group scope preserves tenant domain lists | An exclusive community-only tenant domain baseline. |
| Safety inventory | Reads tenant configuration, all external access policies, group ranks, each Teams user's policy sources, and the selected meeting policy; previews changes and requires explicit `y` | Transactional rollback or a guarantee against concurrent administrator changes. |
| Meeting settings | Reports selected join/lobby/chat fields | Enforcement of anonymous/verified joining, outbound meeting joins, meeting chat, or meeting-policy group assignments. |
| Restricted meeting baseline | `-SetRestrictedMeetingBaseline` configures selected meeting-policy defaults for trusted-org outbound joins, in-meeting-only chat excluding anonymous users, nontrusted external meeting chat disabled, anonymous start disabled, PSTN lobby bypass disabled, and organizer/co-organizer-only lobby admission | Assignment of that meeting policy to the intended organizers/users, tenant-wide anonymous join settings, guest/shared-channel alternate paths, or a guarantee that lobby defaults cannot be changed without templates/labels. |
| Lobby bypass | Optional `SetLobbyBypassForFederated` sets the named meeting policy to `EveryoneInSameAndFederatedCompany` | A prohibition on unapproved external meeting participation. |
| Other paths | No configuration | Consumer access, guest chat, shared channels, tenant restrictions, IB, or DLP. |

**Helper update, October 5, 2026:** `-ExternalCollaborationScope` accepts `Global`
(the backward-compatible default) and `CollaborationGroupOnly`. The latter requires
`-CollaborationGroupId` for **Community Collab Sync - All**; **Community Collaboration - All**
is the access package. No Graph name lookup or second group is introduced.
The custom policy is named `TCG-CommunityCollaboration-<group-object-id>` and allows
exactly the supplied domains. Its consumer and ACS settings are disabled.
Existing tenant blocks covering supplied domains are refused rather than bypassed.
Global warns about custom policies but preserves their precedence and assignments.
Group-only mode refuses federation-capable direct assignments and other-group
assignments conservatively, without assuming which users belong to the selected group.
Existing restrictive assignments remain in effect and can still block selected members.
Group policy rank is preserved on replacement or appended on creation.
`-ReportOnly` and `-WhatIf` do not mutate or prompt for continuation.
Required safety reads fail closed. Applied changes require lowercase `y` and are
not transactional; a failed operation stops without rollback.

Use group-only scope when preserving a deliberate Global federation-deny baseline.
Choosing Global can enable that default again, but only after preview and consent.
The helper now distinguishes Teams meeting admission from Entra `inboundTrust`;
neither scope enforces every meeting/chat/alternate-identity path.

`Community Collab Sync - All` gates outbound provisioning and, when group-only scope
is selected, eligibility for the helper's group-assigned Teams federation policy.
The `External Collaboration Blocked` incompatible-group relationship gates requests for
the access package; it does not itself disable Teams chat, meetings, or existing access.
Reusing the sync gate for Teams eligibility is the selected design; the block group
does not acquire a Teams policy assignment.

## 9. Decisions before changing the helper

These choices are implementation checkpoints, not implied defaults:

| Decision | Alternatives / question |
|---|---|
| Required boundary | Approved users may federate with partners, or no unapproved communication through any path? The latter has documented limitations. |
| Default federation | The helper now supports Global enablement or a group-only organizational federation baseline. Select the scope explicitly when moving between models; other communication paths remain separate decisions. |
| Eligible users | Group-only scope reuses the sync gate. Membership does not imply that the access-package workflow requires approval; direct/competing restrictive policies still take precedence. |
| Blocked users | Does a block group need to select a restrictive Teams policy? How will direct assignments and group rank be reconciled? |
| Partner identity | Which domains/subdomains represent each partner, and which reciprocal users are authorized? |
| Inbound meetings | Required restricted policy defaults are anonymous start off, PSTN lobby bypass off, narrowed lobby admission authority, and separately decided anonymous/email-code joining. |
| Outbound meetings | Required for governed users: `ExternalMeetingJoin = EnabledForTrustedOrgs`; document guest, anonymous, and shared-channel exceptions. |
| Meeting chat | Required: `MeetingChatEnabledType = EnabledInMeetingOnlyForAllExceptAnonymous` and `AllowExternalNonTrustedMeetingChat = $false`; channel/lobby exceptions remain separate. |
| Alternate identities | Teams guest/member paths require inventory and an explicit allow/limit/block decision; default B2B direct connect is blocked and shared channels require separate opt-in design. |
| Enforcement ownership | Which settings may this helper manage, and which remain Entra, Purview, device/network, or partner responsibilities? |
| Deployment safety | Named policy ownership, preservation of unrelated settings, reporting of effective assignments, preview, rollback, and removal behavior. |

An implementation should distinguish **reporting**, **configuration**, and **proven
enforcement**. A successful Set-Cs* command is not evidence that every communication
path now satisfies the requirement.

## 10. Availability, licensing, and acceptance criteria

Granular external-access policies are operationally documented, but this assessment does
not establish an explicit GA announcement, minimum MicrosoftTeams module version, or a
complete GCC/GCC High/DoD/private-cloud availability matrix. Validate parameter presence
and service behavior in the target cloud. Parameter presence alone does not establish
enforcement, especially for the explicitly ineffective controls listed above.

Email verification and enforceable supported meeting-template/label options require
Teams Premium; check applicable Purview licensing for labels, IB, and DLP. Preview
device/network protections must not be presented as an unconditional production boundary.

Use these cases before declaring a group-to-partner restriction effective:

| Test | Required observation |
|---|---|
| G and non-G users initiate and receive B 1:1 chats/calls | Effective policies produce the intended allowed/denied result in both directions. |
| Enabled A user adds non-G A user and B to a group chat | Establish the documented participant-enforcement exposure. |
| B or a third tenant initiates/adds participants | Verify roster authorization, including bilateral-chat settings if selected. |
| Existing chats after policy change or removal from G | Record propagation and continued-access behavior; do not assume instant removal. |
| Every partner domain/subdomain/identity variation | No assumption that one domain covers a tenant or every alias. |
| B users as A B2B identities and shared-channel members | Alternate paths meet their separately defined requirements. |
| Approved/unapproved A organizers and non-G A attendees | Organizer scoping is not confused with participant scoping. |
| Meeting chat before, during, after, and in the lobby | Selected chat controls work within their documented scope. |
| B meetings using A identity, B guest identity, signed-out browser, and unmanaged device | Document `ExternalMeetingJoin` coverage and its exceptions. |
| Anonymous, email-verified, forwarded invitations, dial-in, and channel/event paths | Admission/lobby controls are not misrepresented as identity/group deny rules. |

## Microsoft documentation

The following sources ground the capability assessment. Recheck them and target-cloud
behavior when selecting an enforcement baseline.

- [Granular external access and trusted organizations][granular]
- [External-access policy parameters][external-policy]
- [Tenant federation parameters and reserved-control warnings][tenant-federation]
- [Policy assignment to users and groups][policy-assignment]
- [External versus guest access and identity types][external-guest]
- [External meeting participant identities][meeting-identities]
- [Anonymous and email-verified meeting participation][anonymous-meetings]
- [Lobby controls][lobby]
- [External meeting join restrictions][external-meeting-join]
- [Meeting chat controls][meeting-chat]
- [Teams meeting policy reference][meeting-policy]
- [Meeting templates, sensitivity labels, and policy precedence][meeting-labels]
- [Shared channels][shared-channels]
- [Entra cross-tenant access][cross-tenant]
- [Tenant restrictions v2][tenant-restrictions]
- [Information Barriers in Teams][information-barriers]
- [DLP in Teams][teams-dlp]

[granular]: https://learn.microsoft.com/en-us/microsoftteams/trusted-organizations-external-meetings-chat
[external-policy]: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/set-csexternalaccesspolicy?view=teams-ps
[tenant-federation]: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/set-cstenantfederationconfiguration?view=teams-ps
[policy-assignment]: https://learn.microsoft.com/en-us/microsoftteams/assign-policies-users-and-groups
[external-guest]: https://learn.microsoft.com/en-us/microsoftteams/communicate-with-users-from-other-organizations
[meeting-identities]: https://learn.microsoft.com/en-us/microsoftteams/plan-meetings-external-participants
[anonymous-meetings]: https://learn.microsoft.com/en-us/microsoftteams/anonymous-users-in-meetings
[lobby]: https://learn.microsoft.com/en-us/microsoftteams/who-can-bypass-meeting-lobby
[external-meeting-join]: https://learn.microsoft.com/en-us/microsoftteams/external-meeting-join
[meeting-chat]: https://learn.microsoft.com/en-us/microsoftteams/manage-meeting-chat
[meeting-policy]: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/set-csteamsmeetingpolicy?view=teams-ps
[meeting-configuration]: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/set-csteamsmeetingconfiguration?view=teams-ps
[meeting-labels]: https://learn.microsoft.com/en-us/microsoftteams/meeting-templates-sensitivity-labels-policies
[shared-channels]: https://learn.microsoft.com/en-us/microsoftteams/shared-channels
[channel-policy]: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/set-csteamschannelspolicy?view=teams-ps
[direct-connect]: https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-direct-connect
[guest-messaging]: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/set-csteamsguestmessagingconfiguration?view=teams-ps
[messaging-policy]: https://learn.microsoft.com/en-us/microsoftteams/messaging-policies-in-teams
[cross-tenant]: https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview
[tenant-restrictions]: https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-v2
[information-barriers]: https://learn.microsoft.com/en-us/purview/information-barriers-teams
[teams-dlp]: https://learn.microsoft.com/en-us/purview/dlp-microsoft-teams
