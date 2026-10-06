# Entra-TCG — Session Handoff

> Purpose: get a new chat/agent up to speed on this project quickly. Read this first,
> then skim `ReadMEs\README-Engine.md`, `README-Collaboration.md`, and `README-Hardening.md`.
> Last reviewed: 2026-10-05.

## 1. Where things live

- **Git root:** `C:\Clawpilot\New folder\IC-CIO-ZT`
  - Remote `origin`: `https://ODNI-Services@dev.azure.com/ODNI-Services/IC-CIO-ZT/_git/IC-CIO-ZT`
  - Branch: `andrmass-wip`
  - Top-level `README.md` is a project landing page (repository layout, deployment flow, safety
    notes) — no longer the Azure DevOps stub.
- **Project folder:** `C:\Clawpilot\New folder\IC-CIO-ZT\Entra-TCG`
  - `Scripts\` — `Apply-GraphTemplate.ps1` (engine), `Initialize-TcgDeployerApp.ps1` (certificate
    app-registration setup + token helper for app-only `-AccessToken`, Cloud Shell),
    `Configure-CommunitySyncMappings.ps1`, `Configure-TeamsCollaboration.ps1`,
    `Configure-SharePointSharing.ps1`, `Start-CommunitySync.ps1`
  - `Templates\` — `collaboration.json`, required `hardening.json`
  - `Config\` — `clouds.json` (cloud/endpoint definitions; committed, add clouds offline). A future `partners.json` (real tenant IDs) would be gitignored.
  - `ReadMEs\` — `README-Engine.md`, `README-Collaboration.md`, `README-Hardening.md`, `CloudShellDeployment.md`

## 2. Mental model (the whole project in one paragraph)

A single **generic engine** (`Apply-GraphTemplate.ps1`) reads a declarative JSON template
(`{ graphScopes, resources[] }`) and applies each resource **idempotently** to Microsoft
Entra through `Invoke-MgGraphRequest`. The engine has **no domain knowledge** — every URI,
body, and decision lives in the template. Core templates: **collaboration.json**
(cross-tenant community collaboration, multi-tenant via `forEach` partners) and
**hardening.json** (single-tenant Entra-only baseline). Companion scripts handle surfaces that
do not fit the static template engine: Teams external collaboration (`Cs*` cmdlets), SharePoint
Online sharing (SPO PowerShell), cross-tenant sync mapping customization, and starting sync
after the cross-tenant readiness precondition is met.

## 3. The engine — capability reference

Each resource: `name`, `type` (readability/behavior hint), `mode`
(`create` | `configure` | `assert`), plus capability blocks:

| Block | Meaning |
|---|---|
| `exists` | Lookup (single or ordered array; first match wins) to decide if object is present. Supports `match`, `capture`, `notFoundStatuses`. |
| `create` | POST/PUT when `exists` found nothing. Extras: `guard` (pre-create GET that warns+skips), `retryCount`/`retryDelaySeconds` (replication lag), `capture`. |
| `configure` | PATCH/PUT applied every run (drift correction). Extra: `skipOnConflict` (409/"conflict" ⇒ `[Skipped]`). |
| `assert` | Read-only precondition; warns on fail, never mutates. Supports `decode: json`. |
| `roleScope` | `lookup` (poll until present) + POST — entitlement-management role wiring. |
| `forEach` | Fan resource over a collection (`{ source: "partners", var: "partner" }`). |
| `dependsOn` | Human note only — engine runs in array order. |
| `requires` | Skip resource if a prerequisite capture (e.g. `spId`) is missing. |
| `captureAs` | Store found/created object under a name, promoted **globally** for `{{name.id}}`. |

**`match` mini-JMESPath:** `value`, `value[0]`, `[0]`, `value[?prop]`,
`value[?prop=='literal']`, `a|[0]`, dotted paths. Tokens inside `match` resolve first.

**Tokens (`{{...}}`):** `{{graph-endpoint}}` (env base URL), `{{partner.tenantId}}` /
`{{partner.displayName}}` (in `forEach`), `{{<captureAs>.id}}`, and per-partner captures
`{{spId}}` / `{{appRoleId}}` / `{{jobId}}`. Unresolved tokens fail loudly; under `-WhatIf`
they render `<unresolved:...>` and the dependent lookup is skipped.

**Capture scopes:** global singletons (`group`, `catalog`, `accessPackage`, `noforInternal`,
plus any `captureAs`) and per-partner (`spId`, `appRoleId`, `jobId`, keyed by tenant ID).

**Action kinds / colors:** `Created` (green, new), `Found` (cyan, existed untouched),
`Applied` (green, state enforced), `Asserted` (blue), `Skipped` (gray), `WhatIf` (magenta),
`Warning` (yellow), `Error` (red). `Created` vs `Found` is the true new-vs-existing signal.

**Errors:** default is continue-and-report (exit code 1 if any errors); `-StopOnError` halts.

## 4. Templates

### collaboration.json (21 resources) — multi-tenant, partner-driven
Partners come from `-Domain` (resolved to tenant IDs via OIDC metadata) and/or `-TenantId`.
Model: **internal users** request an access package in their home tenant → membership in the
gate group **Community Collab Sync - All** scopes them into outbound cross-tenant sync
(provisioned as *members*, not guests). Inbound denied by default; partners are an allow-list.
Flow, in array order:
1. Authorization policy (invites) — configure. Invite governance only; the guest access
   tier (`guestUserRoleId`) moved out to hardening.json (2026-09-14).
2. B2B invitation domain restrictions — assert (warn only).
3. Cross-tenant access **per partner** (`forEach`) — create + configure MFA/compliant-device
   trust, consent, and B2B collaboration. Hybrid-join trust is recommended but not required,
   and is not configured by the baseline template.
4. Cross-tenant access default — block inbound B2B collaboration, block default inbound/outbound
   B2B direct connect, and keep default inbound trust disabled.
5–11. Groups (dynamic: External Community Members, External Users All, Internal Members
   Only; governed eligibility: **NOFORN - Internal** `captureAs noforInternal`;
   static governed: **External Collaboration Blocked** `captureAs collaborationBlocked`
   and **Community Collab Sync - All** `captureAs group`). The template-created
   **NOFORN - Internal** default is assigned/static, but an existing dynamic group is allowed
   when its rule uses an approved authoritative eligibility signal. The precondition now
   warns on dynamic membership so administrators can verify the source attribute.
   Note: "External Users All" is provisioned here; hardening no longer creates it.
12–16. Entitlement mgmt: catalog `captureAs catalog`, add group as catalog resource
   (retry/backoff), access package `captureAs accessPackage` + role scope, assignment policy
   (self-service, no approval; requestors scoped to **NOFORN - Internal** `captureAs
   noforInternal` via `specificDirectoryUsers` — replaces the old Forn - All SoD exclusion).
17–21. **Per partner** (`forEach`): sync inbound-allow (PUT), sync app
   `CTS - <Partner>` (create with **guard**, captures `spId`/`appRoleId`), sync job
   (`Azure2Azure`), sync secrets (`CompanyId`=partner tenant, `AuthenticationType`=SyncPolicy),
   sync scope (assign gate group to `msiam_access`). **Sync is configured but NOT started.**

Key operational notes:
- `CTS - <Partner>` display name is the **only** durable readable handle to a sync app's
  target tenant (`CompanyId` secret is write-only). An app with a non-conforming name is
  intentionally not adopted — rename to `CTS - <Partner>` and re-apply to manage it.
- Partner allow entries (res 3) are ordered before the default block (res 4) so existing
  partner relationships aren't interrupted.

### hardening.json v1.2.0 (15 resources) - single tenant, no partner input

Required Entra-only core: Emergency Access group, three creator restrictions,
legacy owner-consent setting create-if-missing, PIM Admin context, and report-only TCG01-TCG10.
TCG08 requires PR-MFA (`...0004`), retains the original fourteen roles and adds
fifteen security-relevant built-in Entra roles; verify role/cloud availability.
Ordinary MFA uses `...0002`. No universal hybrid-join policy or external-users
group provisioning remains in hardening.

Required follow-on: targeted user-consent restriction (no blind grant-policy
collection reset), Limited-or-stricter guest tier (preserve stricter state),
effective consent verification, PR-MFA coverage of eligible/custom/AU-scoped
administrators, native PIM eligibility/activation MFA/bounded activation and
periodic entitlement review. A template run alone is not baseline completion.

Core hardening also deploys TCG09 high-risk activation block and TCG10 fresh
PR-MFA. It guards PIM Admin context creation against an occupied c90, then
reads/captures the dedicated context ID after PATCH returns no body. Verify
reused context ownership/publication. Enable/test policies before attaching the
context to PIM. Native MFA remains independently required.

Full new/legacy CA-name lookup fallbacks prevent blind duplicate creation;
existing objects are not renamed or upgraded. Use the migration table in
README-Hardening; exact-ID reviewed live changes are a separate operator task.
Method/endpoint setup, Teams RSC, Azure PIM and general guest review workstreams
are outside this hardening TCG. Recommendations and future notices are not
current go-live gates. Cloud-native migration notice remains a future program
mandate; ordinary-user PR-MFA/passwordless/device compliance remain optional.

## 5. Companion scripts (can't run through the engine)

- **Configure-TeamsCollaboration.ps1** — Teams external collaboration + meeting/lobby lives in the
  `MicrosoftTeams` module (`Cs*` cmdlets), not Graph. `-ExternalCollaborationScope Global`
  (default) enables the Global federation policy and additively configures tenant allowed
  domains, warning about preserved custom policies. `CollaborationGroupOnly` requires
  `-CollaborationGroupId` for **Community Collab Sync - All**, disables Global federation,
  and assigns `TCG-CommunityCollaboration-<group-object-id>` with the supplied domains.
  No display-name lookup or new group is added; **Community Collaboration - All** is
  the access package. Inventory fails closed; existing federation-capable direct or
  other-group assignments block group-only application rather than being overwritten.
  `-ReportOnly` / `-WhatIf` preview without continuation prompts; changes require `y`.
  Federation is **bidirectional** and policy propagation is asynchronous.
  `-SetLobbyBypassForFederated` is independent and opt-in. Entra inbound trust does not
  independently establish meeting admission, and group scope is not an all-Teams boundary.
- **Configure-CommunitySyncMappings.ps1** — Graph synchronization-schema helper run after
  `collaboration.json` creates the `CTS - <Partner>` app/job and before the job is started.
  It updates the user `displayName` mapping to append an optional `[OrgLabel]` and a
  `SharingSuffix` (default `File Sharing Only`) so synced objects are visibly positioned as
  file/resource-sharing identities rather than Teams chat targets. It truncates the source
  display name as needed to stay within the 256-character Entra `displayName` limit.
- **Configure-SharePointSharing.ps1** — SharePoint Online / OneDrive organization-level sharing
  lives in the `Microsoft.Online.SharePoint.PowerShell` module (`Set-SPOTenant`), not Graph.
  Sets the collaboration baseline to **Existing guests** for both SharePoint and OneDrive,
  organization-only default links, and View as the default link permission. The script reports
  viewer-name and short-link admin-center checkboxes as manual verification items because the
  current public SPO cmdlet reference does not expose stable parameters for them. `clouds.json`
  is not used by SPO PowerShell; pass the SPO admin URL and only pass `-Region` when validated
  for that cloud. RX/EX `Connect-SPOService -Region` values are TBD pending airgap validation.
  It does not set SPO domain restrictions; it only warns if `SharingDomainRestrictionMode` is
  configured, because a domain allow-list must include every community tenant domain.
- **Start-CommunitySync.ps1** — **optional operator convenience (keep-but-demote); the portal is
  the simple manual path** (Entra admin center → Enterprise applications → `CTS - <Partner>` →
  Provisioning → Start provisioning). The final "start job" step has a **cross-tenant precondition**:
  `validateCredentials` only succeeds after the *partner* tenant has enabled inbound sync for
  you (i.e. they've run the collaboration template too). Safe to re-run as tenants come online;
  reports `NotReady` (not an error) until the partner is up. Its edge over the portal: fan-out over
  many partners + re-run as a community onboards over time, and **`-WhatIf` is a readiness probe**
  (runs `validateCredentials` per partner without starting anything). Don't invest further features.

## 6. Prerequisites

- **PowerShell 7+**, module **Microsoft.Graph.Authentication**
  (`Install-Module Microsoft.Graph -Scope CurrentUser`). Teams script needs **MicrosoftTeams**;
  SharePoint sharing needs **Microsoft.Online.SharePoint.PowerShell**.
- **Licensing:** Entra ID P1/P2 (cross-tenant sync is licensed; hardening risk policies +
  PIM need **P2**).
- **Graph scopes** are declared per template (`graphScopes`). Under `-WhatIf` the engine
  swaps in read-only equivalents.
- **Directory roles** for delegated execution: Global Admin, or the documented least-privilege
  role combos (see each README). Both include **Privileged Role Administrator** because both templates
  patch `authorizationPolicy`.

## 7. End-to-end run order (per tenant)

```powershell
cd "C:\Clawpilot\New folder\IC-CIO-ZT\Entra-TCG\Scripts"

# 1. Preview then apply hardening (single tenant)
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json -WhatIf
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json

# 2. Preview then apply collaboration (per partner)
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\collaboration.json -Domain fabrikam.com -WhatIf
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\collaboration.json -Domain fabrikam.com,contoso.com

# 3. Configure cross-tenant sync display-name mapping
.\Configure-CommunitySyncMappings.ps1 -Domain fabrikam.com,contoso.com -OrgLabel FAB -WhatIf
.\Configure-CommunitySyncMappings.ps1 -Domain fabrikam.com,contoso.com -OrgLabel FAB

# 4. Teams trusted external-access domains (every community tenant)
.\Configure-TeamsCollaboration.ps1 -Domains fabrikam.com,contoso.com

# 5. SharePoint/OneDrive sharing baseline
.\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com -WhatIf
.\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com

# 6. (Optional) AFTER every partner has applied collaboration, start sync (re-run as they onboard) —
#    or start per-partner in the portal.
.\Start-CommunitySync.ps1 -Domain fabrikam.com,contoso.com
```
Validate emergency recovery before hardening apply. Complete required targeted
consent/guest/PIM/administrator-coverage checks, review effective state and
report-only impact, then explicitly enable required TCG01-TCG10 and attach the
PIM Admin context to applicable eligible role activation settings. Method setup
is only for actual readiness gaps through its owning guidance.

## 8. Design decisions & rationale (the durable *why*)

Settled calls — don't re-litigate these without a new reason:

- **Engine is domain-agnostic and frozen.** `Apply-GraphTemplate.ps1` owns no knowledge of
  collaboration/hardening — every URI, body, and decision lives in the template. New config is
  added as **JSON templates, never by growing the engine**.
- **Engine owns no auth (`-AccessToken`).** Rejected an in-script `az login`; the engine takes a
  pre-acquired token (SecureString on SDK v2, plaintext on v1), decodes it (`Get-JwtClaims`) to
  read app **roles** / delegated **scp**, and validates via `Test-ScopeSatisfied`
  (ReadWrite⇒Read, broad `Directory.*` coverage). It **hard-fails only when the token carries zero
  Graph roles/scopes** (wrong audience/expired/no consent); a real per-scope miss only warns.
  Recommended acquisition: app-only `az login --service-principal` (cert or MI also work).
- **`Initialize-TcgDeployerApp.ps1` chosen over managed identity.** A user-assigned MI needs a
  compute host (VM/VMSS/ACI/Function) that Cloud Shell can't carry. The deployer is a cert-based
  app (**no client secret**), reads the template's `graphScopes.application` as the **single source
  of truth** for which app roles to grant+consent, and with `-AcquireToken` cert-signs-in and
  returns a Graph token for the engine's `-AccessToken`. Idempotent (ensures/reuses); app/SP named
  **`TCG Deployer`** (generic, reusable); cert files `tcg-deployer.{key,crt,pem}`.
- **`graphScopes` split into `delegated` + `application`.** Keeps app-only-only permissions out of
  the delegated consent request (notably `Directory.ReadWrite.All` (app) vs
  `GroupSettings.ReadWrite.All` (delegated) for hardening). Delegated tokens validate against
  `delegated`; app-only tokens against `application`. A legacy flat array is accepted as delegated.
- **CA auth-strength uses the nested object form** `"authenticationStrength": { "id": "…" }`, **not**
  `@odata.bind`. The bind/navigation form returned **400 BadRequest 1007** on create and left
  policies with no effective grant. (Current TCG03, formerly TCG04, also carries `builtInControls: ["riskRemediation"]`, so
  it kept working and pinpointed the bug.)
- **`TCG03` (formerly TCG04) intentionally keeps `clientAppTypes` + a `sessionControls` block alongside
  `riskRemediation`.** Validated working in the test tenant (a newer session control) — **do NOT
  flag it as a Graph constraint violation.**
- **Authentication methods are NOT scripted.** The auth-methods policy has **no report-only mode**
  and enforces tenant-wide the instant it's written, so a pilot-group scope can lock out the
  operator (happened in testing). FIDO2/CBA/TAP and their pilot groups were removed; methods are a
  separate authentication-method workstream; hardening retains readiness and strength outcomes.
- **SoD replaced by requestor scoping.** The assignment policy scopes requestors to
  **NOFORN - Internal** (`allowedTargetScope: specificDirectoryUsers` → `{{noforInternal.id}}`)
  instead of an SoD incompatible-group exclusion. Same net effect (only governed eligible internal
  members can request), fewer objects. Removed the orphaned **Forn - All** group + its SoD resource
  (referenced a never-captured `{{fornAll.id}}` that would fail at apply).
- **Guest tier is a required hardening outcome, not collaboration.** Collaboration syncs partners as
  *members*, not guests, so guest posture is a tenant-wide hardening concern (invite governance
  stays in collaboration). Verify **Limited or stricter** through state-aware follow-on;
  never downgrade the restricted tier with a static PATCH.
- **Scope boundaries (settled 2026-09-23).** The external/internal segmentation groups in
  `collaboration.json` that no current resource references are intentional segmentation/Purview
  candidates — don't flag them as unused. Monitoring/log ingestion belongs to a separate **Sentinel TCG**.
  Administrator PR-MFA is now required; broader ordinary-user PR-MFA/device compliance is optional.
- **Teams external collaboration stays a typed-param `Cs*` script, not a JSON template.** The Graph
  template/engine pattern only scales because one engine + N templates all reduce to
  `Invoke-MgGraphRequest {uri,method,body}`; Teams `Cs*` cmdlets can't be expressed that way, so any
  new Teams setting requires editing the script regardless. **Shared Channels (B2B Direct Connect)
  and Teams guest access are out of scope** — the design targets external *members* from
  cross-tenant sync.
- **Cloud config kept separate from resource templates (`Config\clouds.json`).** Templates say
  *what*; the cloud file says *which cloud*. Avoids duplicating a cloud map per template and keeps
  the deploy-only `azCloud` field out of resource templates. A `partners.json` (real tenant IDs) was
  **deferred** — saves command-line typing but removes little script logic; would be gitignored.
- **`CTS - <Partner>` display name is the only durable readable handle** to a sync app's target
  tenant (the `CompanyId` secret is write-only). An app with a non-conforming name is **intentionally
  not adopted** — rename to `CTS - <Partner>` and re-apply to manage it.

## 9. Deployment & auth specifics (current state)

- **Cloud resolution (`Resolve-CloudConfig`, shared by all three scripts):** `-Environment <name>`
  is looked up in a `clouds.json` (`{ clouds: { <name>: { graphEndpoint, loginHost, mgEnvironment,
  azCloud } } }`), falling back to built-in `Global`/`USGov`/`USGovDoD` — **a file is only required
  for a custom/sovereign name**. `-Environment` is open-ended (no `ValidateSet`). **Resolution
  order:** explicit `-CloudConfigPath` > `..\Config\clouds.json` > `.\Config\clouds.json` >
  `clouds.json` beside the script (the last keeps the **flat Cloud Shell upload** layout working).
  File entries override built-ins of the same name; unknown name + no file fails loudly. Per-script
  validation: engine/starter need `graphEndpoint`+`loginHost`+`mgEnvironment`; deployer needs
  `graphEndpoint`+`azCloud`. `Config\clouds.json` is committed (3 public clouds + a `Sovereign`
  placeholder; add clouds offline by copying an entry). `.gitignore` ignores only a future
  `Config\partners.json`.
- The `Custom*` script params (`-CustomGraphEndpoint`/`-CustomLoginHost`/`-CustomMgEnvironment`/
  `-CustomAzCloud`) and the per-script `-Environment Custom` branches were **removed** in favor of
  the above.

## 10. Still open / manual / by design

- **Required follow-on:** state-aware consent/guest settings, native PIM settings,
  eligible/admin coverage, effective-state checks, migration/readiness and explicit
  TCG01-TCG10 enforcement. Attach the PIM Admin context to applicable eligible
  role activation settings only after TCG09/TCG10 are enforced and validated.
  Coordinate the old device-registration MFA toggle with TCG07.
- **Optional:** admin-consent workflow, selective PIM approval, ticket numbers,
  notifications, custom PKI strength and broader authentication/device targets.
- **Context c90:** the core template never overwrites an occupied context; policies
  use a captured dedicated-context ID. Do not attach the context until enforced
  gates are verified.
- **Pending target-cloud validation:** beta risk remediation, new role availability,
  supported owner-consent mechanism and method-strength compatibility. No silent skips.
- **Git:** `git` CLI may not be on PATH in the review environment (repo state read from `.git\config`).
  Don't commit/push unless the user says so; when they do, use branch `andrmass-wip` and keep the
  `Co-authored-by: Copilot` trailer.

## 11. Changelog (thin — full detail in git history)

- **2026-10-05:** approved item-level hardening scope implemented in repository:
  required core TCG01-TCG08, optional PIM context TCG09/TCG10 module, PR-MFA admin
  strength and added Entra role coverage, safe full-name legacy lookups, targeted
  manual consent/guest follow-on preserving existing state, native PIM core and
  route-specific simplified deployment. Universal hybrid join/unused external-users
  provisioning and out-of-scope workload/endpoint/storage procedures removed from
  hardening guidance. Engine remains unchanged.
- **2026-10-06:** PIM Admin context and report-only TCG09/TCG10 promoted into
  required `hardening.json` core (15 resources). `AuthenticationContext.ReadWrite.All`
  is now required by the core template.
- **2026-10-05:** approved collaboration review alignment implemented in repository:
  collaboration template remains **21 resources** with a NOFORN precondition assert,
  removes unapproved guest/NOFORN country-rule groups, keeps **NOFORN - Internal** as a governed
  eligibility group that may be assigned or dynamic when based on an approved authoritative signal, blocks
  default B2B direct connect, keeps default inbound trust disabled, drops required
  partner hybrid-join trust, and adds `Configure-TeamsCollaboration.ps1
  -SetRestrictedMeetingBaseline` for the approved meeting-policy defaults.
  `Apply-GraphTemplate.ps1` assert mode now supports explicit `onFail.action = error`
  for safety preconditions while preserving warn-only asserts by default.
- **2026-09-10:** `-TemplatePath` made mandatory with pre-connect JSON/`resources` validation;
  `-AccessToken` app-only auth added (`Get-JwtClaims`/`Test-ScopeSatisfied`); README examples/help
  updated; stale `tenant-config-fixed.json` reference removed.
- **2026-09-11:** collaboration → **21 resources** (Forn-All group + SoD removed, requestor scoping
  added, idempotency + `mailNickname` fixes); hardening → **16 resources** (auth-methods + pilot
  groups removed, auth-strength switched to nested form); `graphScopes` split delegated/application;
  `New-DeployerApp.ps1` → **`Initialize-TcgDeployerApp.ps1`** (app renamed `TCG Deployer`) with
  custom-cloud support; companion `.docx` reconciled; top-level `README.md` became a landing page.
- **2026-09-14:** `guestUserRoleId` moved collaboration → hardening (limited tier `10dae51f-…`).
- **2026-09-21:** `Configure-TeamsFederation.ps1` now checks/enables the Global external-access gate
  (`EnableFederationAccess`) + bidirectional reminders (Shared Channels / guest access out of scope);
  cloud config moved to `Config\clouds.json` with shared `Resolve-CloudConfig` + built-in fallback,
  all `Custom*` params removed; companion `.docx` reconciled to the guest-tier move.
- **2026-09-23:** HANDOFF compacted — chronological changelog collapsed into §8 rationale + this thin
  log; current-state facts folded into §1–7 and §9. Top-level `README.md` Deployment flow gained a
  **"Selecting or adding a cloud"** subsection (add a `clouds.json` entry + pass its key via
  `-Environment`, worked example `AgencyCloud`); the per-tenant deployment block now threads
  `-Environment` through hardening/collaboration/start-sync (Teams external collaboration excluded — no cloud config).
  **Start-CommunitySync.ps1 demoted** to an optional convenience in the docs (portal is the simple
  manual path; script's edge is multi-partner fan-out, safe re-run as a community onboards, and a
  `-WhatIf` readiness probe) — no script/behavior change. **Tagged `v1.0.0-rc.1`** (feature-complete,
  validated in commercial labs; pending end-to-end validation in the sovereign target cloud before `v1.0.0`).
  Post-tag: `es-metadata.yml` fixed for the 1ES inventory schema (ownership/routing; `directOwners` reduced to 2).
- **2026-09-23:** delegated role sets corrected in both READMEs — **Authentication Policy Administrator
  removed** from hardening (auth methods are manual by design, §8); **Privileged Role Administrator added**
  to both (Graph lists it as the least-privileged role for `PATCH /policies/authorizationPolicy`, hardening
  res 3 / collaboration res 1; app-only runs are unaffected). Companion guides updated to match (maintained
  outside the repo).
- **2026-09-28:** added `Configure-SharePointSharing.ps1` companion script for the SPO/OneDrive
  organization-level sharing baseline (Existing guests, organization-only default links, View permission);
  documented it in the collaboration run flow. Engine remains frozen.
- **2026-09-28:** renamed `Configure-TeamsFederation.ps1` to `Configure-TeamsCollaboration.ps1`
  and updated it to treat `-Domains` as additive trusted Teams external-access domains, preserving
  any existing allowed domains instead of replacing the list.
- **2026-09-28:** added `Configure-CommunitySyncMappings.ps1` to configure the CTS job
  `displayName` mapping with optional `[OrgLabel]` plus a sharing suffix (default `File Sharing Only`)
  before sync starts.
