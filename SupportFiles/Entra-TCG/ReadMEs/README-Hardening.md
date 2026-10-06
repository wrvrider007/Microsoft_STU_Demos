# Entra ID Hardening - Required Baseline and Future Enhancements

## Scope and application model

This TCG hardens **Microsoft Entra**, not all of Microsoft 365. Teams-specific
resource-specific consent (RSC) belongs in a separate Teams TCG. Collaboration
guidance may span Entra, Teams and SharePoint when needed for its outcome.
Authentication-method deployment, endpoint/MDM configuration, Azure resource-role
PIM and general guest lifecycle reviews are not hardening deployment workstreams.

`Templates\hardening.json` v1.2.0 has **15 resources**: the Emergency Access
exclusion group, default creator restrictions, a legacy owner-consent settings
object, the PIM Admin authentication context, and ten required CA policies. New CA policies are **report-only**;
authorization settings take effect immediately. Existing create-mode objects are
found and **left unchanged**, not reconciled, renamed or upgraded.

**Applying the template alone does not complete the baseline.** Required
state-aware consent/guest checks, administrator coverage, native PIM settings,
effective-configuration review and explicit CA enforcement remain follow-on
steps. Do not interpret `Found`, `Skipped`, or a successful run as compliance.
The generic engine is unchanged.

Run from `Entra-TCG\Scripts` (or adapt paths for flat uploads):

```powershell
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json -WhatIf
# Only after reviewing the target and immediate changes:
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json -StopOnError
```

`-Environment Global`, `USGov`, or `USGovDoD` selects a built-in cloud; other names
require a validated `clouds.json`. Omit partner `-Domain`/`-TenantId` inputs:
hardening acts on the signed-in tenant. See [README-Engine.md](README-Engine.md)
and [CloudShellDeployment.md](CloudShellDeployment.md) for authentication routes.

## Required outcomes

| Area | Required baseline | How applied |
|---|---|---|
| Emergency recovery | At least two cloud-only, non-federated `.onmicrosoft.com` accounts; permanent-active Global Administrator; independently registered phishing-resistant credentials; strong random passwords where retained; secure resilient custody | Manual readiness; reuse qualifying accounts |
| Recovery exceptions | Effective exclusions from all enabled CA policies that could restrict recovery, including existing non-TCG policies | Template uses Emergency Access; direct exclusions are a valid manual alternative |
| Emergency operations | Emergency-only use and post-use review, monitoring/alerts, initial and recurring recovery tests, designated trusted secure administrative client | Existing processes; monitoring configuration belongs to the Sentinel TCG |
| Administrative identities | Dedicated cloud-only human privileged-admin identities; remove privileged Entra roles from synchronized identities after validating replacement access | Manual assignment review/migration, not user-account deletion |
| Creator permissions | Ordinary users cannot register apps, create security groups or create tenants; explicitly authorized delegation remains possible | Authorization-policy PATCH |
| User consent | Ordinary users cannot independently grant new OAuth permissions; existing grants are not revoked | Targeted follow-on below, not a blanket collection reset |
| Owner consent | Applicable Entra Group/owner consent restrictions and verification of effective coverage | Legacy setting create-if-missing; verify supported control; Teams RSC implementation is owned by Teams TCG |
| Guest directory access | Limited **or stricter** for Guest identities; never downgrade an existing stricter setting | State-aware follow-on below; external Members are not covered by guest tier |
| User authentication | General MFA, risky-sign-in fresh MFA, high-user-risk remediation, legacy/device-code restrictions, registration MFA | TCG01-TCG07 after readiness/impact review |
| Privileged authentication | Phishing-resistant MFA for applicable human administrators, including eligible identities and PIM activation | TCG08, TCG10, and actual administrator coverage review |
| Entra role PIM | Applicable human assignments eligible rather than standing; native activation MFA; bounded role-appropriate activation; PIM Admin context attached after TCG09/TCG10 are enforced and validated; initial assignment inventory and periodic entitlement review | Core template plus manual Entra role settings; emergency accounts remain permanent active |

Secure custody must remain available during an identity outage; the affected
tenant must not be the sole credential-retrieval dependency. A physical vault is
recommended, not mandated where an equivalent arrangement meets the outcome.
Review every emergency use; investigate unexplained activity rather than treating
every planned drill as a full incident. Quarterly/90-day tests and routine
post-use password rotation are recommendations; suspected exposure still requires
appropriate incident-response rotation/revocation. Password rotation does not
revoke passkeys, certificates or sessions.

## Required Conditional Access policies

New policies exclude the captured Emergency Access group. It is created empty
if missing: validate and populate it before enforcement. The assigned group is
a convenient implementation, **not a required new group**; manual deployments
may use documented direct account exclusions. Protect group membership.

MFA strength is `00000000-0000-0000-0000-000000000002`; phishing-resistant
strength is `00000000-0000-0000-0000-000000000004`.

| Policy | Users and resources | Trigger | Grant/session |
|---|---|---|---|
| TCG01 - Require MFA for all users | All users, all resources | All client types | Built-in MFA strength |
| TCG02 - Protect risky sign-ins | All users, all resources | High **and medium** sign-in risk levels (either triggers) | MFA strength; every-time primary/secondary authentication |
| TCG03 - Protect risky users | All users, all resources | High user risk | Risk remediation **AND** MFA strength; mandatory every-time authentication |
| TCG04 - Block legacy authentication | All users, all resources | Legacy `exchangeActiveSync` / `other` client categories | Block |
| TCG05 - Block device code flow | All users, all resources | `deviceCodeFlow` | Block |
| TCG06 - Protect security info registration | All users; register-security-info action | All client types | MFA strength; no extra device/location/session condition |
| TCG07 - Protect device registration | All users; register-or-join-devices action | All client types | MFA strength; **no every-time session control** |
| TCG08 - Protect Admin Roles | Selected built-in directory roles, all resources | All client types | **Phishing-resistant** MFA strength |
| TCG09 - PIM Admin - Block high user risk | All users requesting the PIM Admin context | High user risk | Block |
| TCG10 - PIM Admin - Require Auth Strength | All users requesting the PIM Admin context | All client types | Phishing-resistant MFA strength; every-time primary/secondary authentication |

TCG02 is not redundant with general MFA: it adds fresh authentication on risk.
TCG03 addresses identity compromise, not only a suspicious sign-in; do not merge
the risk policies so that both conditions must be present. TCG03 retains the
newer `riskRemediation` grant (Graph **beta** creation), including passwordless
remediation; do not substitute an unconditional password-change grant.

TCG04 is not a protocol-wide ban on every EAS/SMTP use. TCG05 covers modern
device-code authentication, which can satisfy MFA; legacy blocking does not
replace it. Authentication transfer is a separate feature and is not blocked here.
Inventory legitimate dependencies; additional exceptions must be individually
approved, documented and secured, not a blanket exemption for administrators
or all service accounts. User-based service accounts can be affected; service
principals are not targeted by these user CA policies.

Before registration enforcement, validate a supported bootstrap path and
external-user registration. Existing method compatibility matters: ordinary MFA
claims/external methods do not necessarily satisfy the configured strength.
Do not require every user to already possess a phishing-resistant credential just
to enroll their first one. Method enablement, TAP issuance, PKI and pilot scope
procedures belong in authentication-method guidance, not this deployment.

**TCG07 prerequisite:** coordinate Entra's older **Require MFA to register or
join devices** tenant setting to **No** with enforced CA registration protection.
Microsoft warns that the CA user action is not properly enforced with the older
switch enabled. Do not turn off existing protection while the replacement is
merely report-only; stage, approve and validate the transition.

### Administrator roles and coverage

TCG08 retains Microsoft's recommended 14-role minimum and adds security-relevant
built-in Entra roles. These are **human role holders**, not a recommendation to
assign any role or deploy every underlying feature.

| Set | Roles |
|---|---|
| Original tenant/security | Global Administrator; Privileged Role Administrator; Security Administrator; Conditional Access Administrator |
| Original users/credentials | User Administrator; Helpdesk Administrator; Password Administrator; Authentication Administrator; Privileged Authentication Administrator |
| Original apps/services | Application Administrator; Cloud Application Administrator; Exchange Administrator; SharePoint Administrator; Billing Administrator |
| Added authentication/trust | Authentication Policy Administrator; Hybrid Identity Administrator; Domain Name Administrator; External Identity Provider Administrator; Authentication Extensibility Administrator |
| Added access/lifecycle | Groups Administrator; Identity Governance Administrator; Lifecycle Workflows Administrator; Attribute Provisioning Administrator; Directory Writers |
| Added devices/response | Cloud Device Administrator; Entra SOC Identity Responder; Security Operator |
| Added newer capabilities | Agent ID Administrator; Tenant Governance Administrator |

Preflight role availability and CA support in the target cloud, particularly for
newer roles. An unavailable role is a deployment issue to resolve explicitly,
not a reason to silently omit protection for an actual administrator. The role
IDs are in the template; this list is **not every role carrying the preview
Privileged label**.

Review the actual administrator roster. Built-in role targeting does not cover
custom/AU-scoped assignments or prove protection of eligible administrators
before activation. Extend supported targeting or use explicit administrator
account/group targeting where needed, with the approved emergency exclusions.
No universal new admin group is mandated. TCG08's template role list alone is
not evidence that this coverage requirement is met.

## State-aware authorization follow-on (required)

The static template PATCH contains only the three required creator restrictions.
It deliberately does **not** clear `permissionGrantPoliciesAssigned`, or reset
`guestUserRoleId` to Limited. Those unconditional writes would violate the
approved preservation requirements.

Using the **same verified tenant/cloud**, read `/v1.0/policies/authorizationPolicy`
through Graph or the corresponding portal settings before any targeted update.
Use `Policy.Read.All` for the read and `Policy.ReadWrite.Authorization` for a
Graph update; delegated updates require Privileged Role Administrator.

| Check | Required targeted action |
|---|---|
| User consent assignments | Remove ordinary-user self-consent assignments (`managePermissionGrantsForSelf.*`). Inspect other developer/owned-resource policies; retain them **only after explicit approval**, not simply because they already exist. PATCH only the reviewed `defaultUserRolePermissions.permissionGrantPoliciesAssigned` collection in the v1.0 authorization policy; do not replace unrelated properties. An empty collection is valid if no approved paths remain, but is not an unconditional baseline reset. |
| Guest tier | If already Limited (`10dae51f-b6af-4016-8d66-8c2a99b929b3`) or Restricted (`2af84b1e-32c8-42b7-82bc-daa82404023b`), preserve it. Change member-equivalent guest defaults to at least Limited after approval. Stop and investigate unrecognized state; never downgrade Restricted. |
| Owner consent | Inspect the existing Group.Unified values and applicable supported Entra owner-consent control. The template sets `EnableGroupSpecificConsent=false` **only when creating** a missing settings object. Preserve other values on any approved update. This legacy setting alone does not prove current Teams RSC coverage. Cross-reference the Teams TCG for team/chat/personal-scope controls. |

Read again after applying the reviewed change and verify the effective outcome.
Do not reset other authorization-policy properties or existing consent grants.
Guest directory restrictions are not a Teams/SharePoint content-access boundary.

## Native PIM configuration (required, manual)

Review Entra role assignments using Discovery and Insights, role views, or an
equivalent current read-only inventory. Convert applicable human administrative
assignments to eligible; document other approved exceptions and handle workload
principals separately. **PIM is role-assignment/settings work, not a single
tenant-wide on/off switch.**

For applicable Entra roles require native **MFA on activation** and a bounded,
role-appropriate activation maximum (supported range 1-24 hours). Reuse suitable
existing limits; no universal hour count is prescribed. Native MFA can accept
earlier satisfied MFA: it is not a fresh or phishing-resistant guarantee.
Independently protect eligible admin accounts with the approved PR-MFA coverage.
Periodically review entitlement need and record retain/remove decisions; existing
review processes are acceptable and automated access-review campaigns optional.

Require justification for every applicable Entra role activation. Selective
approval (especially GA/PRA), notification recipient tuning, ticket numbers,
and PIM for explicitly privileged Entra groups are **recommended, not
required**. If approval is adopted, configure available approvers (preferably
two) and preserve recovery; no external PAM/ticket workflow is mandated.

## PIM Admin context deployment and enforcement

The core template creates or reuses a verified dedicated PIM Admin context and
creates TCG09/TCG10 in report-only mode. The context is not a standalone control:
after report-only review, enforce and validate both policies before attaching the
context to applicable eligible Entra role activation settings.

| Policy | Scope | Requirement |
|---|---|---|
| TCG09 - PIM Admin - Block high user risk | All users requesting the dedicated context; emergency exclusions | Block high user risk at activation |
| TCG10 - PIM Admin - Require Auth Strength | Same context/users | PR-MFA strength plus every-time authentication |

Before applying, inspect context ownership, ID, display name and publication.
The template reuses a **verified dedicated** `PIM Admin Context` by name, or
creates `c90` if unused. It never overwrites a context. If an unrelated `c90`
exists, creation is guarded and dependent policies are skipped unless a dedicated
context can be found. Resolve warnings/skips; they are not successful protection.
To choose another free ID, change the context creation URI. Policies bind to the
captured context ID, not a separate hard-coded ID. Reject duplicate names and
verify any reused context is published and dedicated to this purpose.

The context PATCH returns no body, so a separate read captures its ID before
policy creation. Preview can skip dependent policies when the context has not yet
been created; review them again once prerequisites exist. Ensure both policies
are enforced, correctly targeted and tested **before** attaching the context to
eligible Entra role activation settings. PIM's backup MFA does not activate merely
because a context policy is report-only, disabled, or excludes the user.
Every-time reauthentication has a documented 10-minute tolerance across
activations. Context gates elevation, not every subsequent privileged session;
TCG08 and eligible-account coverage remain independently required.

## Safe migration from v1.0.0

| Old policy | New policy / disposition |
|---|---|
| TCG01 - Require MFA for all users | TCG01 |
| TCG02 - Require Hybrid Entra Join | Removed from baseline; review live retirement separately |
| TCG03 - Protect risky sign-ins | TCG02 |
| TCG04 - Protect risky users | TCG03 |
| TCG05 - Block legacy authentication | TCG04 |
| TCG06 - Block device code flow | TCG05 |
| TCG07 - Protect security info registration | TCG06 |
| TCG08 - Protect device registration | TCG07; no extra session-frequency requirement |
| TCG09 - Protect Admin Roles | TCG08; upgrade MFA to PR-MFA and review expanded coverage |
| TCG10 - PIM Admin - Block high user risk | TCG09 |
| TCG11 - PIM Admin - Require Auth Strength | TCG10; requires PR-MFA |

Templates look up the **complete new display name first**, then the complete
legacy display name for the same control. Matching only `TCG02`, for example,
would confuse the old hybrid policy with the new risk policy. These fallbacks
prevent blindly duplicating a known legacy control; they do **not** rename or
upgrade it. `Found` can leave an old ordinary-MFA admin policy in place.

Inventory exact IDs and full names, detect duplicates (including old and new
copies), export current settings, then approve targeted rename/configuration
changes. Preserve unrelated conditions/exceptions and the current policy state.
Review PR-MFA readiness before upgrading an enabled policy; do not silently
reset it to report-only or strengthen it without that review. Retire the old hybrid policy or old PIM gates only through an approved live change.
Removing a resource from JSON does not delete or disable its tenant object.
Existing `External Users All` and collaboration configuration remain untouched.

## Permissions and capability preflight

| Route | Core template permissions |
|---|---|
| Delegated | `Group.ReadWrite.All`, `Policy.ReadWrite.Authorization`, `Policy.ReadWrite.ConditionalAccess`, `Policy.Read.All`, `GroupSettings.ReadWrite.All`, `AuthenticationContext.ReadWrite.All` |
| Application | Same, except `Directory.ReadWrite.All` replaces delegated `GroupSettings.ReadWrite.All` |

Delegated core deployment requires Conditional Access Administrator, Groups
Administrator and Privileged Role Administrator, or a suitable authorized
higher-privilege identity. PIM/method/portal follow-on tasks have their own role
requirements; do not confuse the deployer's Graph scopes with those permissions.
`Application.Read.All` and authentication-method write permission are not core
template requirements.
App-only directory write privilege remains broad: grant deliberately and use
delegated/manual owner-setting configuration where appropriate.

Required risk policies need Entra P2; native PIM needs P2 or applicable Entra
Governance entitlement. Confirm licensing for affected users and exact feature,
API, role and authentication-strength availability in the target cloud, especially
beta `riskRemediation`. Endpoint selection does not establish feature parity.
If a required capability is unavailable, stop and resolve the gap/approved
exception; do not silently omit the control.

`-WhatIf` performs no writes, but the unchanged engine only maps certain
delegated write scopes to read equivalents. It can still request a write scope
for group settings or the PIM context; a supplied token retains all its
granted privileges. For strict read-permission preview, supply an appropriate
read-only token. Never describe the token itself as read-only just because
`-WhatIf` was used.

## Simplified go-live

1. Confirm the tenant/cloud and validate both emergency accounts, custody, secure
   client and effective exceptions. Reuse accounts/groups rather than duplicate.
2. Choose **one** execution route; check retained-control licensing, capabilities,
   runtime (if scripted), selected permissions and actual administrator coverage.
3. Preview/review changes. Distinguish immediate creator/settings writes from
   report-only CA creation and explicitly reviewed manual consent/guest changes.
4. Apply selected core configuration; complete required state-aware follow-on
   and native PIM settings. Review all errors, warnings, skips and effective state.
5. Verify authentication/bootstrap readiness, registration toggle transition,
   existing-policy migration and report-only impact. Refer to method/endpoint
   guidance only for actual readiness gaps; do not mandate reconfiguration.
6. Explicitly enable and validate **TCG01-TCG10** after approval, then attach the
   PIM Admin context to applicable eligible role activation settings. Future
   migration is not a gate. Configure monitoring through its owning TCG and remove
   approved temporary deployment credentials when finished.

## Optional guidance and future notice

| Item | Treatment |
|---|---|
| Five-or-fewer Global Administrators | Recommended minimization target, not hard cap; include emergency accounts and justify exceptions |
| Exclude privileged AD accounts from sync | Recommended upstream AD Tier-0 hygiene; assess dependencies, no mandatory OU-move workstream |
| Most-restrictive guest tier | Recommended tenant-specific tightening; check workload compatibility and preserve existing stricter state |
| M365 group/Teams creator restriction | Optional Entra group-governance setting; security-group restriction does not block Team creation |
| Designated M365 creators group | Optional only if creation restricted; reuse a suitable group and check applicable licensing |
| Built-in admin-consent request workflow | Optional; existing organizational approval process acceptable |
| Custom admin certificate strength / issuer / OID restrictions | Optional PKI-specific assurance; built-in PR-MFA remains the baseline |
| Ordinary-user PR-MFA / passwordless | Optional readiness-driven expansion, not a mandatory second baseline |
| Compliant-device Entra CA | Optional future device assurance with supported signals; no hybrid-join placeholder or endpoint integration recipe |
| Manual configuration mapping | Optional alternative/reference, not a second mandatory configuration pass |

**Future program requirement, not enforced by this release:** a subsequent
baseline is planned to require cloud-native authentication for currently
federated users. Administrators should assess dependencies and prepare. That
baseline will define scope, timing, prerequisites and exceptions. This is program
direction, not a universal Microsoft mandate or current go-live condition.

Authentication-method combination matrices may be retained as **nonmandatory
reference** with verified current strength definitions; use the linked Microsoft
reference, not an assumption that every MFA claim or certificate combination
meets phishing-resistant strength.

Removed workstreams: unused external-users group provisioning in hardening;
universal hybrid join; LinkedIn; portal-friction toggle; BitLocker owner-recovery
and directory-read configuration steps; general guest reviews; Azure-role PIM;
MDM/compliance integration recipes; compulsory Azure Files/SMB infrastructure.
Removal from guidance does not authorize live setting changes.

## Microsoft references

- [Default user permissions](https://learn.microsoft.com/entra/fundamentals/users-default-permissions)
- [User consent and preserving other grant policies](https://learn.microsoft.com/entra/identity/enterprise-apps/configure-user-consent)
- [Guest directory restrictions](https://learn.microsoft.com/entra/identity/users/users-restrict-guest-permissions)
- [Emergency access](https://learn.microsoft.com/entra/identity/role-based-access-control/security-emergency-access)
- [Sign-in risk policy](https://learn.microsoft.com/entra/identity/conditional-access/policy-risk-based-sign-in)
- [User-risk remediation](https://learn.microsoft.com/entra/identity/conditional-access/policy-risk-based-user)
- [Device-code restrictions](https://learn.microsoft.com/entra/identity/conditional-access/policy-block-authentication-flows)
- [Security-info registration](https://learn.microsoft.com/entra/identity/conditional-access/policy-all-users-security-info-registration)
- [Device registration and legacy MFA switch](https://learn.microsoft.com/entra/identity/conditional-access/policy-all-users-device-registration)
- [Admin PR-MFA and role-targeting limits](https://learn.microsoft.com/entra/identity/conditional-access/policy-admin-phish-resistant-mfa)
- [Built-in roles](https://learn.microsoft.com/entra/identity/role-based-access-control/permissions-reference)
- [PIM settings, context ordering and reauthentication tolerance](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-how-to-change-default-settings)
- [Authentication strengths](https://learn.microsoft.com/entra/identity/authentication/concept-authentication-strengths)
- [Teams RSC: separate Teams-TCG implementation](https://learn.microsoft.com/microsoftteams/platform/graph-api/rsc/grant-resource-specific-consent)
