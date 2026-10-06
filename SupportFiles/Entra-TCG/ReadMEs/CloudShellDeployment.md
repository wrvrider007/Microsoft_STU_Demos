# Graph Template Deployment - Cloud Shell and Supplied Tokens

## Choose one route

This guide describes execution/authentication, not additional baseline controls.
For required Entra outcomes and manual follow-on checks, use
[README-Hardening.md](README-Hardening.md). Applying a template is not proof that
its required outcomes are enforced.

| Route | Use when | Setup |
|---|---|---|
| Delegated Graph sign-in | A supported interactive sign-in is available | Authorized operator, required module and selected template scopes |
| Certificate-based app-only | Interactive/device-code auth is unsuitable or prohibited | Optional `Initialize-TcgDeployerApp.ps1` helper and a dedicated temporary deployer |
| Existing supported token source | An approved certificate/managed-identity/MSAL host already exists | Correct Graph audience and selected template application roles or delegated scopes |
| Manual configuration | Script execution is unsuitable | Applicable portal/Graph permissions and the hardening reference mapping |

Do **not** require both local and Cloud Shell execution, or multiple authentication
routes. Device-code blocking can affect interactive tooling; do not exempt every
administrator or create a deployment app automatically to bypass it.

Cloud Shell needs no dedicated deployment storage account, Azure Files share,
storage RBAC, SMB mount, shared key, or managed-identity compute host. Upload the
scripts/templates directly, or clone an authorized repository into the chosen
execution host. Keep the `Scripts`, `Templates`, and optional `Config` structure,
or adapt paths for a flat upload. Existing optional storage is not deleted by
these instructions.

## Before execution

Confirm the **tenant and cloud**, working emergency recovery, selected controls,
licensing and exact target-cloud API/feature support. Hardening core requires
its retained risk controls, PIM Admin context policies, and native PIM.

Scripted execution needs PowerShell 7+ and `Microsoft.Graph.Authentication`.
Cloud Shell includes Azure CLI and PowerShell; check module availability in the
actual session. Install only the missing required module, not every Graph module.
Additional manual PIM tasks need their own authorized roles.

The selected template's `graphScopes.delegated` and `graphScopes.application`
are the source of truth. Delegated and application permissions are alternatives,
not a combined universal grant list. Hardening no longer requests `Application.Read.All` or authentication-method
write permission. Its core template requests `AuthenticationContext.ReadWrite.All`
for the required PIM Admin context.

App-only `Directory.ReadWrite.All` remains a broad hardening requirement for the
selected group-settings API. Grant it deliberately; a delegated/manual settings
route is an alternative. Never extend the Azure CLI first-party app's tenant-wide
consent merely to make this deployment work.

## Route A - delegated deployment

From PowerShell in `Entra-TCG\Scripts`, using the verified cloud:

```powershell
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json `
    -Environment USGov -WhatIf

# Review the target and changes before this separate applying command.
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json `
    -Environment USGov -StopOnError
```

Use `Global` or `USGovDoD` when appropriate. The engine's `-WhatIf` makes no
mutations, but maps only certain delegated write scopes to read equivalents.
Unmapped group-settings/context scopes may still be requested. For a preview
with strictly read-only permissions, supply an appropriate read-only token.
With `-AccessToken`, the token retains whatever privileges it was granted.

## Route B - optional certificate deployer

Use a dedicated identity and working directory for each deployment lifecycle.
The helper reads the selected template's application-role list, creates/reuses
an app/service principal and certificate, grants the roles, verifies propagation,
and optionally returns a SecureString Graph token. Setup requires an authorized
active role for granting the selected Graph application permissions; Global
Administrator or Privileged Role Administrator can perform the privileged grant
operation. This is setup authority, not a requirement for ordinary administration.

The certificate is a privileged private key, not a harmless script artifact.
Protect it and do not publish it, copy it into the repository, or log token text.

```powershell
# Run in the deployment working directory; adapt helper/template paths as needed.
$token = .\Initialize-TcgDeployerApp.ps1 `
    -TemplatePath ..\Templates\hardening.json -Environment USGov -AcquireToken

.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json `
    -Environment USGov -AccessToken $token -WhatIf

# Separate approved apply:
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\hardening.json `
    -Environment USGov -AccessToken $token -StopOnError
$token = $null
```

`-AcquireToken` switches Azure CLI to the deployment service principal. Return
to the verified user/tenant before administration or cleanup.

Setup writes `deployerAppConfig.json` in the working directory. It records exact
application object/client IDs, tenant/cloud, and certificate paths, not tokens
or private-key contents. Keep it protected until approved cleanup is complete;
it is gitignored. Do not overwrite it for a different deployment identity.

### PIM Admin context

The core template deploys the context bundle. Verify the dedicated context,
publication, warnings/skips and actual policy configuration. New policies are
report-only. Enforce/test them before attaching the context to PIM role settings.

### Collaboration execution

The same route works with the collaboration template and its own permissions:

```powershell
$token = .\Initialize-TcgDeployerApp.ps1 `
    -TemplatePath ..\Templates\collaboration.json -Environment USGov -AcquireToken
.\Apply-GraphTemplate.ps1 -TemplatePath ..\Templates\collaboration.json `
    -Environment USGov -Domain fabrikam.com -AccessToken $token -WhatIf
```

Review and apply separately using the collaboration guidance. No collaboration
template or Teams/SPO policy changes are implied by this hardening revision.

## Supplied tokens and cloud selection

`-AccessToken` takes a SecureString acquired outside the engine. The engine does
not run Azure CLI or handle a client secret. Tokens are short-lived: reacquire
through the chosen authorized source instead of retaining raw tokens.

| Environment | Azure CLI cloud | Graph audience |
|---|---|---|
| Global | AzureCloud | `https://graph.microsoft.com` |
| USGov | AzureUSGovernment | `https://graph.microsoft.us` |
| USGovDoD | AzureUSGovernment | `https://dod-graph.microsoft.us` |

For a custom cloud, use the validated `Config\clouds.json` entry, register the
Azure CLI cloud if needed, and pass the same `-Environment` to helper and engine.
Built-in clouds do not require new configuration. The helper uses `azCloud` and
`graphEndpoint`; the engine also needs `loginHost` and `mgEnvironment`.
Both support `-CloudConfigPath`; default search includes `..\Config`, `.\Config`,
and the script directory for flat uploads.

Token audience, tenant and runtime cloud must agree. Selecting a cloud does not
prove that beta risk remediation, newer roles, authentication strengths, or
other required features are available there.

The engine reports decoded token roles/scopes and checks the selected template
list. Missing permissions can be **warnings**, not a hard stop; a real request
may then fail. Review every resource error and the final summary. Token decoding
is not local signature validation; Graph validates requests. `Found` does not
establish desired settings.

Managed identity is reference-only for an **existing supported host**. Cloud
Shell is not assumed to carry a user-assigned identity; do not provision compute
solely to make this route mandatory. A delegated Azure CLI user token carries
the CLI app's existing scopes, not necessarily the template's required scopes.

## Required completion steps for hardening

1. Complete targeted user-consent and Limited-or-stricter guest-access checks;
   preserve approved unrelated grant paths and any stricter guest tier.
2. Review resource errors/warnings/skips and effective settings, including
   existing legacy policies. Creation does not rename or upgrade them.
3. Complete native Entra role PIM and PR-MFA coverage of eligible administrators.
4. Validate authentication/bootstrap readiness, emergency exclusions,
   registration MFA-toggle transition, and report-only impact.
5. Explicitly enforce required TCG01-TCG10 after approval, then attach the PIM
   Admin context to applicable eligible role activation settings. Removed policies
   are not automatically disabled/deleted.

See the hardening README's full-name migration table before renumbering existing
tenant policies. Do not turn policy-name changes into duplicate enforcement or
silent strengthening of an enabled policy.

## Approved cleanup of a temporary deployer

A dedicated throwaway deployer must not leave standing privileged credentials
after deployment. Do **not** delete a reused production app; agree its lifecycle
separately. Removing local files alone does not revoke a registered credential.

From the directory containing the original `deployerAppConfig.json`, return to
an authorized user in the recorded tenant:

```powershell
$config = Get-Content -LiteralPath .\deployerAppConfig.json -Raw | ConvertFrom-Json
az login --tenant $config.tenantId
.\Initialize-TcgDeployerApp.ps1 -Cleanup -WhatIf

# Inspect exact targets, then approve each deletion separately with y.
.\Initialize-TcgDeployerApp.ps1 -Cleanup
```

Cleanup validates the recorded cloud, tenant and exact application object ID.
It prompts separately for app deletion and recorded certificate/key files;
neither an app-name guess nor unrelated paths are cleanup targets.
If app deletion succeeds but local cleanup does not, use the retained config
to finish removing only the recorded local files; the missing application can
prevent a second automatic cleanup. Deleting the deployer does not remove
objects provisioned by the templates.

## Troubleshooting

| Symptom | Action |
|---|---|
| App-role grant missing after setup | Verify setup authority and selected template; allow directory propagation; inspect helper output |
| Wrong/no token roles or request authorization failure | Verify tenant/cloud/audience, expiry and exact granted permissions; do not ignore per-resource errors |
| Old policy reported Found | It remains unchanged; use approved targeted migration, not another blind create |
| Context collision / missing context capture | Resolve core-template context prerequisites; do not attach PIM context after a skipped policy |
| Required capability absent in target cloud | Stop and resolve the gap/approved exception; do not claim baseline completion |
| Cleanup tenant/identity mismatch | Use original config and correct tenant; never guess another app by display name |
