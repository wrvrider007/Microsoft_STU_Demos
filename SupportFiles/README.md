# IC-CIO-ZT

This repository contains the Entra Technical Configuration Guide (TCG) deployment package for Microsoft Entra collaboration and security hardening.

The current implementation lives under [`Entra-TCG`](Entra-TCG). It uses a generic PowerShell engine, `Apply-GraphTemplate.ps1`, to apply declarative JSON templates idempotently through Microsoft Graph. The engine has no scenario-specific logic; each template declares the Graph permissions, resource order, lookups, create/configure actions, and captured values it needs.

## Repository layout

| Path | Purpose |
|---|---|
| [`Entra-TCG\Scripts`](Entra-TCG/Scripts) | Deployment scripts: the generic Graph template engine, Cloud Shell deployer-app/token helper, cross-tenant sync mapping helper, Teams external collaboration script, SharePoint sharing script, and cross-tenant sync starter. |
| [`Entra-TCG\Templates`](Entra-TCG/Templates) | Declarative Entra templates: `collaboration.json` and required `hardening.json`. |
| [`Entra-TCG\Config`](Entra-TCG/Config) | Deployment config: `clouds.json` (cloud/endpoint definitions; committed — add entries for new clouds offline). A future `partners.json` (real tenant IDs) is gitignored. |
| [`Entra-TCG\ReadMEs`](Entra-TCG/ReadMEs) | Technical references for the engine, each template, and Cloud Shell deployment. |
| [`Entra-TCG\HANDOFF.md`](Entra-TCG/HANDOFF.md) | Current project handoff, implementation notes, and changelog. Read this first when picking up the project. |

## What the templates do

### Collaboration

[`collaboration.json`](Entra-TCG/Templates/collaboration.json) configures a cross-tenant collaboration baseline for community tenants. It creates or configures tenant-wide collaboration settings, per-partner cross-tenant access relationships, dynamic/static groups, an entitlement-management access package, and staged outbound cross-tenant synchronization.

Key behavior:

- Partner tenants are supplied with `-Domain` and/or `-TenantId`.
- Inbound B2B collaboration is blocked by default; configured partners form the allow-list.
- Internal users request the access package in their home tenant.
- Membership in `Community Collab Sync - All` scopes users into outbound cross-tenant synchronization.
- Requestors are scoped to `NOFORN - Internal`.
- Synchronization is configured but not started by the template. Start it per partner once reciprocal setup is complete — in the portal, or with `Start-CommunitySync.ps1` (convenient for many partners and for re-running as they onboard).

See [`README-Collaboration.md`](Entra-TCG/ReadMEs/README-Collaboration.md).

### Hardening

[`hardening.json`](Entra-TCG/Templates/hardening.json) stages the required single-tenant **Entra-only** hardening controls: the Emergency Access exclusion group, creator restrictions, a legacy owner-consent setting, PIM Admin context, and Conditional Access policies TCG01-TCG10. Targeted user-consent and Limited-or-stricter guest access, native PIM settings, administrator coverage and effective-state verification remain **required follow-on steps**, not unconditional template resets.

Key behavior:

- Conditional Access policies are created in report-only mode.
- Every policy excludes the Emergency Access group.
- Ordinary-user requirements use the built-in MFA strength; TCG08 and TCG10 require **phishing-resistant MFA** for the selected admin roles and PIM activation, respectively. Eligible/custom/AU-scoped administrator coverage needs separate verification.
- Native Entra role PIM eligibility, activation MFA, justification, bounded activation, PIM Admin context attachment after TCG09/TCG10 enforcement, and entitlement review are required.
- Authentication-method/endpoint deployment and Teams-specific hardening belong to separate guidance. The universal hybrid-join policy and unused hardening external-users group provisioning are removed.
- Full new/legacy policy-name lookups avoid blindly duplicating known renamed controls. Existing objects remain unchanged; live rename, strength upgrades and policy retirement require a separately approved migration.

See [`README-Hardening.md`](Entra-TCG/ReadMEs/README-Hardening.md).

## Deployment flow

Run from PowerShell 7+ with the Microsoft Graph PowerShell module available.

### Selecting or adding a cloud

`Apply-GraphTemplate.ps1`, `Start-CommunitySync.ps1`, and `Initialize-TcgDeployerApp.ps1` resolve their endpoints by cloud name via `-Environment`. `Global` (the default), `USGov`, and `USGovDoD` are built in and need no configuration.

For any other cloud — including a sovereign or air-gapped cloud — add an entry to [`Entra-TCG\Config\clouds.json`](Entra-TCG/Config/clouds.json) under `clouds`, keyed by the `-Environment` name you will pass. For example, to add an `AgencyCloud` environment:

```json
"AgencyCloud": {
  "graphEndpoint": "https://graph.agency.gov",
  "loginHost": "login.agency.gov",
  "mgEnvironment": "AgencyCloud",
  "azCloud": "AzureAgencyCloud"
}
```

- `graphEndpoint` - Microsoft Graph base URL / token audience for the cloud.
- `loginHost` - OIDC login host used to resolve partner domains to tenant IDs.
- `mgEnvironment` - Microsoft.Graph SDK environment name (`Connect-MgGraph -Environment`).
- `azCloud` - Azure CLI cloud name (`az cloud set`); used only by `Initialize-TcgDeployerApp.ps1`.

A file entry overrides a built-in of the same name. The scripts search `-CloudConfigPath` (if supplied), then `..\Config\clouds.json`, then `.\Config\clouds.json`, then `clouds.json` beside the script — so a flat Cloud Shell upload works by dropping `clouds.json` next to the scripts. `Configure-TeamsCollaboration.ps1` uses the Microsoft Teams module and takes no `-Environment`.

### Per-tenant deployment

The common per-tenant order is (pass the cloud name you configured above as `-Environment`; omit it to use the default `Global` cloud):

```powershell
cd .\Entra-TCG\Scripts

# 1. Validate emergency recovery, then preview and apply selected hardening.
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json -Environment AgencyCloud -WhatIf
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json -Environment AgencyCloud -StopOnError
# Complete required consent/guest/PIM/coverage checks in README-Hardening before enforcement.

# 2. Preview and apply collaboration for one or more partners.
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\collaboration.json -Environment AgencyCloud -Domain fabrikam.com -WhatIf
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\collaboration.json -Environment AgencyCloud -Domain fabrikam.com,contoso.com

# 3. Configure cross-tenant sync display-name mapping for the staged CTS app/job.
.\Configure-CommunitySyncMappings.ps1 -Environment AgencyCloud -Domain fabrikam.com,contoso.com -OrgLabel FAB -WhatIf
.\Configure-CommunitySyncMappings.ps1 -Environment AgencyCloud -Domain fabrikam.com,contoso.com -OrgLabel FAB

# 4. Configure Teams trusted external-access domains for the same partner domains (Teams module; no -Environment).
.\Configure-TeamsCollaboration.ps1 -Domains fabrikam.com,contoso.com -ExternalCollaborationScope Global

# Alternatively, restrict organizational federation to the existing sync-gate security group.
# Supply the Community Collab Sync - All object ID, NOT the Community Collaboration - All access-package ID.
.\Configure-TeamsCollaboration.ps1 -Domains fabrikam.com,contoso.com `
    -ExternalCollaborationScope CollaborationGroupOnly `
    -CollaborationGroupId '<security-group-object-id>' -WhatIf

# 5. Configure SharePoint/OneDrive sharing (SPO module; no -Environment).
.\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com -WhatIf
.\Configure-SharePointSharing.ps1 -AdminUrl https://contoso-admin.sharepoint.com

# 6. (Optional) After each partner has applied reciprocal collaboration setup, start sync.
.\Start-CommunitySync.ps1 -Environment AgencyCloud -Domain fabrikam.com,contoso.com
```

Step 6 is optional. A sync job can also be started per partner in the portal (Entra admin center → Enterprise applications → `CTS - <Partner>` → Provisioning → **Start provisioning**). The script is the convenience for a community that onboards over time: it fans out over many partners, is safe to re-run as each becomes ready (partners not yet ready report `NotReady`, not an error), and with `-WhatIf` acts as a **readiness probe** — running `validateCredentials` for each partner without starting anything.

SharePoint Online PowerShell does not use `clouds.json`. For sovereign tenants, pass the tenant's SharePoint admin center URL to `-AdminUrl`; for GCC High and DoD, also pass `-Region ITAR` if the SPO module needs the sovereign authentication region. RX/EX SPO regions are not assumed in this repo; validate the required `Connect-SPOService -Region` value in the airgap cloud before documenting or automating one.

For environments where interactive/device-code sign-in is unsuitable, the optional `Initialize-TcgDeployerApp.ps1` certificate helper can acquire an app-only Graph token for `Apply-GraphTemplate.ps1 -AccessToken`. Choose one execution/authentication route; Azure Files infrastructure is not a hardening prerequisite. Protect and remove approved temporary deployment credentials after use.

See [`CloudShellDeployment.md`](Entra-TCG/ReadMEs/CloudShellDeployment.md) and [`README-Engine.md`](Entra-TCG/ReadMEs/README-Engine.md).

## Operational safety notes

- The engine is idempotent: repeated runs find existing objects, create missing objects, and re-apply declared configuration where appropriate.
- `-WhatIf` performs a read-only preview and requests read-only delegated scopes where possible.
- `-TemplatePath` is required and the template is validated before Graph connection.
- The default error model is continue-and-report; use `-StopOnError` to halt on first failure.
- Validate both cloud-only emergency accounts before hardening apply and verify effective exceptions before CA enforcement. The templates use a dedicated group; documented direct exclusions are a valid manual alternative.
- Review report-only Conditional Access impact before enforcing policies.
- Verify authentication/bootstrap readiness before enforcement; reconfigure methods only for an actual gap through separate method guidance.
- Do not start cross-tenant synchronization until every participating partner tenant has enabled inbound sync for the source tenant.

## Documentation index

- [`Entra-TCG\HANDOFF.md`](Entra-TCG/HANDOFF.md) - current handoff and changelog.
- [`README-Engine.md`](Entra-TCG/ReadMEs/README-Engine.md) - generic engine reference.
- [`README-Collaboration.md`](Entra-TCG/ReadMEs/README-Collaboration.md) - collaboration template reference.
- [`README-Teams-Collaboration-Gates.md`](Entra-TCG/ReadMEs/README-Teams-Collaboration-Gates.md) - Teams chat/meeting controls, enforcement gaps, and decisions before extending the Teams helper.
- [`README-Hardening.md`](Entra-TCG/ReadMEs/README-Hardening.md) - hardening template reference.
- [`CloudShellDeployment.md`](Entra-TCG/ReadMEs/CloudShellDeployment.md) - Cloud Shell, deployer app, `-AccessToken`, and sovereign-cloud guidance.
