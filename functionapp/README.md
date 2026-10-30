# Azure Function serverless runner

This folder contains the scheduled-ingestion scaffold for the enterprise-native FinOps runner. Native mode is the preferred production path; CLI bridge mode remains for local development, POC, custom-container Functions, or Container App Jobs where Azure CLI is intentionally available.

The timer trigger calls:

```text
scripts\Invoke-FinOpsServerlessRun.ps1
```

## Native execution model

Standard Azure Function hosts should not be assumed to include Azure CLI. Production deployments should use `FINOPS_EXTRACTION_MODE=Native`, which uses:

```text
Az.Accounts token acquisition
Managed identity or service principal auth
Invoke-RestMethod for ARM / Cost Management / Billing APIs
Azure SQL durable-store loading
```

The native auth foundation is in:

```text
scripts\FinOpsNativeAuth.psm1
scripts\Test-FinOpsNativeAuth.ps1
scripts\Invoke-FinOpsNativeCostExport.ps1
scripts\Invoke-FinOpsNativeBillingAudit.ps1
scripts\Invoke-FinOpsNativeRetailEnrichment.ps1
scripts\Update-FinOpsNativeHistory.ps1
```

For local native-auth testing, sign in with Az.Accounts first:

```powershell
Connect-AzAccount -Tenant "<tenant-id>" -Environment AzureCloud
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FinOpsNativeAuth.ps1 -AzureCloud AzureCloud -AuthMode Existing
```

For Azure Government:

```powershell
Connect-AzAccount -Tenant "<tenant-id>" -Environment AzureUSGovernment
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FinOpsNativeAuth.ps1 -AzureCloud AzureUSGovernment -AuthMode Existing
```

## Required app settings

For private outbound Cost Management connectivity in Azure Commercial, use the opt-in [Bicep ARM Private Link deployment](../infra/bicep/README.md#deploy-arm-private-link). It requires an Elastic Premium plan, VNet integration, private ARM DNS, and a separately approved tenant-root association. Keep the existing ARM URL and managed identity authentication unchanged. ARM Private Link does not privatize Retail Prices or enforce public-egress denial; validate the actual Function path with the documented diagnostic and network evidence.

| Setting | Example | Notes |
| --- | --- | --- |
| `FINOPS_TIMER_SCHEDULE` | `0 0 6 * * *` | NCRONTAB schedule. |
| `FINOPS_EXTRACTION_MODE` | `Native` or `CliBridge` | `Native` uses Az.Accounts + REST for core Cost/Billing exports. `CliBridge` uses existing Azure CLI scripts for full retail enrichment/history/SQL loading during transition. |
| `FINOPS_AUTH_MODE` | `ManagedIdentity`, `ServicePrincipal`, or `Existing` | `Existing` is for custom hosts that pre-authenticate Azure CLI. |
| `FINOPS_AZURE_CLOUD` | `AzureCloud` or `AzureUSGovernment` | One function app can be deployed per cloud, or separate schedules can be introduced later. |
| `FINOPS_TENANT_ID` | tenant GUID | Required for service principal auth. |
| `FINOPS_SUBSCRIPTION_IDS` | comma-separated subscription IDs | Target subscriptions. |
| `FINOPS_OUTPUT_ROOT` | writable path / mounted share | Run evidence output. |
| `FINOPS_HISTORY_ROOT` | writable path / mounted share | Durable CSV history path. |
| `FINOPS_SQL_ENABLED` | `true` | Enables Azure SQL durable-store load. |
| `FINOPS_SQL_SERVER` | `server.database.windows.net` | Azure SQL logical server FQDN. |
| `FINOPS_SQL_DATABASE` | `FinOpsMaccRetail` | Target database. |
| `FINOPS_SQL_SCHEMA` | `finops` | Target schema. |
| `FINOPS_RUN_BILLING_AUDIT` | `true` or `false` | Defaults to true. |

For service principal auth, also set:

```text
FINOPS_CLIENT_ID
FINOPS_CLIENT_SECRET
```

Prefer managed identity. If service-principal auth is required, set `FINOPS_CLIENT_SECRET` as a Key Vault reference, not as a plain app setting:

```text
FINOPS_CLIENT_SECRET=@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/finops-client-secret/<version>)
```

The Bicep deployment can optionally create an RBAC-enabled Key Vault and grant the Function identity `Key Vault Secrets User`; the secret value must still be seeded through a secured deployment process.

## Extraction modes

| Mode | Use | Current limitations |
| --- | --- | --- |
| `Native` | Enterprise target path. Uses native Az.Accounts + REST for Cost Management and Billing extraction without Azure CLI. Updates actual-cost, retail-match, billing, and MACC/audit durable history and can load Azure SQL. | Preferred production mode. |
| `CliBridge` | Transitional/local/POC path. Reuses the existing Azure CLI scripts end to end. | Requires Azure CLI in the host image/environment. |

## Monitoring output

The runner writes explicit App Insights-friendly status markers to host logs:

```text
FinOpsRunStatus=Started
FinOpsRunStatus=Succeeded
FinOpsRunStatus=Failed
```

The Bicep deployment can optionally create Azure Monitor scheduled-query alerts that watch these traces for failed runs and missed successful runs.

When `FINOPS_SQL_ENABLED=true`, the SQL loader writes a compact health summary to the Function transcript after each load. The same status can be queried from:

```text
finops.IngestionFreshnessByCloud
finops.IngestionFreshnessBySubscription
finops.RetailMatchCoverageByCloud
finops.OperationalHealthSummary
```

Use these views for freshness visuals or alert rules that watch stale loads, missing cost rows, missing retail matches, and low retail match coverage.
