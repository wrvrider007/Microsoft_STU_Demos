# Apply-GraphTemplate.ps1 — Engine Reference

A generic, idempotent PowerShell engine that applies declarative JSON templates to
Microsoft Entra via `Invoke-MgGraphRequest`. The engine has **no domain knowledge** —
every resource, URL, and payload lives in the template. The same engine drives
`collaboration.json`, required `hardening.json`, or any future template.
Hardening's required
manual/state-aware follow-on steps are documented in **README-Hardening.md**.

> Requires **PowerShell 7+** and the **Microsoft.Graph.Authentication** module
> (`Install-Module Microsoft.Graph -Scope CurrentUser`).

---

## Mental model

A template is `{ "graphScopes": { "delegated": [...], "application": [...] }, "resources": [...] }`.
The engine:

1. Resolves the target **partners** (from `-Domain` / `-TenantId`).
2. Connects to Graph. In **delegated** sign-in it requests `graphScopes.delegated` (read-only
   equivalents where mapped under `-WhatIf`; unmapped scopes remain unchanged).
   With an **`-AccessToken`**, an app-only token is validated
   against `graphScopes.application` and a delegated token against `graphScopes.delegated`.
3. Walks `resources` **in array order**, applying each one **idempotently** based on
   the blocks it declares (`exists`, `create`, `configure`, `assert`, `roleScope`, …).
4. Prints a per-resource action line and a final summary tally.

> **`graphScopes` shape.** `delegated` lists the Microsoft Graph **delegated** scopes used for
> interactive/user sign-in; `application` lists the equivalent **app roles** used by an app-only
> `-AccessToken` identity (service principal or managed identity). The two usually match by name,
> but some delegated scopes have no app-role equivalent — e.g. `GroupSettings.ReadWrite.All`
> (delegated) maps to the broader `Directory.ReadWrite.All` (application). Splitting them keeps
> app-only-only permissions **out of the delegated consent request**. A legacy flat array
> (`"graphScopes": [...]`) is still accepted and treated as the delegated set.

Idempotency model: the engine **checks then acts**. `create` resources only write when
`exists` finds nothing; `configure` resources PATCH/PUT the desired state every run
(drift correction). Existing `create` objects are not updated, renamed, or verified
against the body. Reapplication is not a complete drift-reconciliation pass.
Review `configure` writes, which can immediately reassert tenant-wide settings.

---

## Parameters

| Parameter | Purpose |
|---|---|
| `-TemplatePath <path>` | **Required.** Template to apply. Must exist and contain valid JSON (validated before connecting to Graph). |
| `-Domain <string[]>` | One or more partner domains; resolved to tenant IDs via the OIDC metadata endpoint. |
| `-TenantId <string[]>` | One or more partner tenant IDs (GUIDs). Combine freely with `-Domain`. |
| `-Environment <name>` | `Global` (default), `USGov`, and `USGovDoD` are built in; any other name (e.g. an AGC/sovereign cloud) must be defined in a `clouds.json` (see `-CloudConfigPath`). |
| `-CloudConfigPath <path>` | Optional path to a `clouds.json` mapping cloud names to `{ graphEndpoint, loginHost, mgEnvironment, azCloud }`. If omitted, the script searches `..\Config\clouds.json`, `.\Config\clouds.json`, and `clouds.json` beside the script (the last covers flat Cloud Shell uploads). File entries override the built-in three. |
| `-AccessToken <securestring>` | Authenticate Graph with a **pre-acquired access token** instead of Graph PowerShell's interactive/device-code sign-in — for environments where that flow is broken (e.g. Azure Cloud Shell in some clouds). Acquire the token however you like (an app registration with the template's Graph **application** permissions is recommended); its audience must match `-Environment`. The engine decodes and validates the token's roles/scopes. See [CloudShellDeployment.md](CloudShellDeployment.md). |
| `-WhatIf` | Preview. Reads state, shows would-do actions, commits nothing. Maps supported delegated write scopes to read equivalents; unmapped scopes and supplied-token privileges remain unchanged. |
| `-StopOnError` | Halt on first failure. Default is **continue-and-report** (exit code 1 if any errors). |
| `-Verbose` | Also print the exact `METHOD uri` for each action. |

`{{graph-endpoint}}` in the template is replaced with the selected environment's Graph
endpoint, so one template works across clouds.

### Examples

```powershell
.\Apply-GraphTemplate.ps1 -TemplatePath .\collaboration.json -Domain fabrikam.com -WhatIf
.\Apply-GraphTemplate.ps1 -TemplatePath .\collaboration.json -Domain fabrikam.com,contoso.com
.\Apply-GraphTemplate.ps1 -TemplatePath .\hardening.json -WhatIf
.\Apply-GraphTemplate.ps1 -TemplatePath .\collaboration.json -TenantId 1111...,2222... -Environment USGov -Verbose
.\Apply-GraphTemplate.ps1 -TemplatePath .\collaboration.json -Environment Sovereign   # 'Sovereign' defined in Config\clouds.json
```

---

## Resource anatomy

Every resource has `name`, `type` (the Graph resource identity, used for readability
and per-type behavior), and `mode` (`create` / `configure` / `assert`). It then
declares one or more capability blocks:

| Block | Meaning |
|---|---|
| `exists` | Lookup to decide if the object is already present (see below). |
| `create` | POST/PUT to make the object when `exists` found nothing. |
| `configure` | PATCH/PUT applied idempotently every run (drift correction). |
| `assert` | Read-only precondition check; never mutates. |
| `roleScope` | `lookup` (poll until present) + POST — entitlement-management role wiring. |
| `forEach` | Fan this resource out over a collection (currently `partners`). |
| `dependsOn` | Human-readable ordering note (engine runs in array order). |
| `requires` | Skip the resource if a prerequisite capture is missing. |
| `captureAs` | Store the found/created object under a name for later `{{name.id}}` use. |

### `exists`

A single lookup **or an ordered array** of lookups (first match wins):

```json
"exists": {
  "method": "GET",
  "uri": "{{graph-endpoint}}/v1.0/groups?$filter=displayName eq 'X'",
  "match": "value[0]",
  "capture": { "myId": "value[0].id" },
  "notFoundStatuses": [404]
}
```

- **`match`** — a mini-JMESPath expression evaluated against the response. Tokens
  (`{{...}}`) inside `match` are resolved first, so you can match on captured values.
- **`capture`** — pull fields from the response into named tokens.
- **`notFoundStatuses`** — statuses treated as "not found" instead of errors (default `404`).
- Provide an **array** of lookups to try a primary key then a fallback.
- Hardening uses full new/legacy policy names to avoid duplicating known legacy
  controls after renumbering. A fallback hit is still unchanged; migration and
  effective-control verification remain separate approved steps.

### `match` mini-expression grammar

| Form | Meaning |
|---|---|
| `value` | property access |
| `value[0]` / `[0]` | array index |
| `value[?prop]` | filter: items where `prop` is truthy |
| `value[?prop=='literal']` | filter: items where `prop` equals a literal |
| `a\|[0]` | pipe: take first of a filtered set |
| `a.b.c` | dotted path through the above |

Example: `value[?displayName=='msiam_access']|[0].id`

### `create` — extra options

```json
"create": {
  "method": "POST",
  "uri": "...",
  "body": { ... },
  "capture": { "id": "id" },
  "retryCount": 6,
  "retryDelaySeconds": 15,
  "guard": {
    "uri": "...",
    "match": "value[0]",
    "message": "Existing object detected; skipping create to avoid duplication."
  }
}
```

- **`retryCount` / `retryDelaySeconds`** — retry-with-backoff on transient failures
  (e.g. directory replication lag when a just-created group isn't visible yet). A short
  `[Info]` line is printed between attempts. Default: no retries.
- **`guard`** — a pre-create GET; if it returns a match, the engine **warns and skips
  the create** instead of duplicating or touching unmanaged configuration.

### `configure` — extra options

```json
"configure": { "method": "PUT", "uri": "...", "body": { ... }, "skipOnConflict": true }
```

- **`skipOnConflict`** — if the mutation fails with a conflict (HTTP 409 or a
  `Request_MultipleObjectsWithSameKeyValue` / "conflicting object" error), report
  `[Skipped]` (already in desired state) instead of failing. Non-conflict errors still throw.

### `assert`

Read-only precondition. Missing object = pass. Supports decoding serialized JSON fields:

```json
"assert": {
  "when": "found",
  "predicate": { "path": "definition[0]", "decode": "json", "select": "a.b.AllowedDomains", "mustBe": "emptyOrAbsent" },
  "onFail": { "action": "warn", "message": "..." }
}
```

On failure the engine prints a `[Warning]` (with `{{value}}` filled from the offending
data) and continues — it never mutates state it doesn't own.

### `roleScope`

For entitlement-management role wiring, which needs a value that only exists after an
async operation settles. Runs a `lookup` (polling until a resource appears), captures
from it, then POSTs:

```json
"roleScope": {
  "lookup": { "method": "GET", "uri": "...", "waitUntil": "value[0]", "capture": { "resourceId": "value[0].id" } },
  "method": "POST", "uri": ".../resourceRoleScopes", "body": { ... "{{roleScope.lookup.resourceId}}" ... }
}
```

### `forEach`, `requires`, `captureAs`

- **`forEach`** — `{ "source": "partners", "var": "partner" }` runs the resource once
  per partner, exposing `{{partner.tenantId}}` and `{{partner.displayName}}`.
- **`requires`** — `["spId"]` skips the resource with a clear message when a prerequisite
  capture isn't available (e.g. a dependent step whose producer was intentionally skipped).
- **`captureAs`** — stores the object under a name and promotes it **globally** so later
  resources can reference `{{name.id}}`. Any name works.

---

## Token resolution (`{{...}}`)

- `{{graph-endpoint}}` — the selected environment's Graph base URL.
- `{{partner.tenantId}}`, `{{partner.displayName}}` — inside `forEach` resources.
- `{{<captureAs>.id}}` — any object captured earlier (e.g. `{{catalog.id}}`, `{{fornAll.id}}`).
- `{{spId}}`, `{{appRoleId}}`, `{{jobId}}` — per-partner captures from the sync chain.
- Unresolved tokens **fail loudly**; under `-WhatIf` they render as `<unresolved:...>`
  and the dependent lookup is skipped (because its producer hasn't been created yet).

Captures are stored in two scopes: **global** (singletons like `group`, `catalog`,
`accessPackage`, plus any `captureAs`) and **per-partner** (`spId`, `appRoleId`, `jobId`,
keyed by tenant ID so each partner's sync chain binds to its own service principal).

---

## Output & action kinds

Each resource prints one colored action line; the run ends with a summary tally.

| Action | Color | Meaning |
|---|---|---|
| `[Created]` | Green | New object created. |
| `[Applied]` | Green | Desired state (re-)asserted via PATCH/PUT (configure / role scope). |
| `[Found]` | Cyan | Already existed; untouched. |
| `[Asserted]` | Blue | Precondition passed. |
| `[Skipped]` | DarkGray | Nothing to do / prerequisite missing / conflict = already done. |
| `[WhatIf]` | Magenta | Preview only. |
| `[Warning]` | Yellow | Non-blocking issue (failed assert, guard skip). |
| `[Error]` | Red | Failed. |

`Created` vs `Found` is the true new-vs-existing signal. `Applied` means "state
enforced" (may or may not have changed anything) — this is intentional and safe for a
config-enforcement tool. Use `-Verbose` to also see the exact call per action.

---

## Error handling

- Default: **continue-and-report** — a failed resource logs `[Error]` and the run
  proceeds; exit code is `1` if any errors occurred.
- `-StopOnError` halts on the first failure.
- Expected non-2xx responses are handled gracefully where declared
  (`notFoundStatuses`, `skipOnConflict`, guard, `requires`), so only genuine failures surface.

---

## Extending the engine

Because the engine is data-driven, most new scenarios need **only a new template** —
no code changes. Add engine code only when a template needs a genuinely new capability
(a new block type or match form). Existing general primitives worth reusing:
`exists` arrays, `guard`, `requires`, `retryCount`, `skipOnConflict`, equality `match`
filters, and tokens inside `match`.
