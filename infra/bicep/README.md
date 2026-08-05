# Bicep deployment

This folder contains the first enterprise deployment baseline for the Azure FinOps MACC Retail durable-store architecture.

It deploys:

- Azure Storage account for the Function runtime
- Application Insights
- Azure SQL logical server
- Azure SQL database
- optional SQL firewall rule
- optional VNet, Function VNet integration, Azure SQL private endpoint, and SQL private DNS zone/link
- PowerShell Azure Function App with system-assigned managed identity
- Function app settings for native FinOps ingestion
- optional RBAC-enabled Azure Key Vault for service-principal secrets
- optional Azure Monitor scheduled-query alerts backed by Application Insights traces

This folder also includes `role-assignments.bicep`, a separate subscription-scope helper for assigning Azure RBAC roles to the Function managed identity.

## Deploy

From the repository root:

```powershell
az deployment group create `
  --resource-group "<resource-group>" `
  --template-file .\infra\bicep\main.bicep `
  --parameters .\infra\bicep\main.parameters.example.json
```

Or pass parameters inline:

```powershell
az deployment group create `
  --resource-group "AzureFinOps" `
  --template-file .\infra\bicep\main.bicep `
  --parameters `
    workloadName="finops" `
    environmentName="prod" `
    location="westus3" `
    sqlServerName="<existing-or-new-sql-server-name>" `
    sqlDatabaseName="FinOpsMaccRetail" `
    finOpsTenantId="<tenant-id>" `
    finOpsSubscriptionIds="<subscription-id>" `
    functionPlanSkuName="EP1" `
    enablePrivateNetworking=true `
    sqlPublicNetworkAccessEnabled=false `
    enableKeyVault=true `
    enableMonitoringAlerts=true `
    alertNotificationEmail="finops-ops@example.com"
```

`sqlServerName` is a parameter. To target an existing SQL server, pass its logical server name:

```powershell
sqlServerName="<existing-sql-server-name>"
```

Use the logical SQL server name only, not the FQDN. For example, use `<server-name>`, not `<server-name>.database.windows.net`.

If the SQL server already exists, run the deployment against the resource group that contains that server. This template treats the SQL server as a managed resource in the target resource group; cross-resource-group reuse of an existing SQL server would require a separate `existing`-resource variant.

## Required post-deployment steps

1. Deploy the `functionapp` folder to the created Function App.
2. Grant the Function managed identity Cost Management Reader on target subscriptions. You can use the subscription-scope helper after the main deployment returns `functionPrincipalId`:

```powershell
az deployment sub create `
  --location "<deployment-location>" `
  --template-file .\infra\bicep\role-assignments.bicep `
  --parameters functionPrincipalId="<function-principal-id>"
```

By default this assigns:

| Role | Role definition ID |
| --- | --- |
| Cost Management Reader | `72fafb9e-0641-4937-9268-a91bfd8191a3` |

To add subscription-scope Billing Reader as well, pass both role IDs:

```powershell
az deployment sub create `
  --location "<deployment-location>" `
  --template-file .\infra\bicep\role-assignments.bicep `
  --parameters `
    functionPrincipalId="<function-principal-id>" `
    roleDefinitionIds='["72fafb9e-0641-4937-9268-a91bfd8191a3","fa23ad8b-c56e-40d8-ac0c-ce449e1d2c64"]'
```

3. Grant any required Billing Reader/Billing account roles at the customer's actual billing account/profile scope when subscription-scope RBAC is not sufficient for billing evidence.
4. Grant the Function managed identity access to Azure SQL:

```sql
CREATE USER [<function-app-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<function-app-name>];
ALTER ROLE db_datawriter ADD MEMBER [<function-app-name>];
```

Use more restrictive custom roles/procedures as the SQL writer hardens.

5. Deploy the SQL schema. If SQL public network access is disabled, run this from a Bastion-accessed jump box, a VPN/ExpressRoute-connected workstation, or a self-hosted deployment agent inside the VNet:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Deploy-FinOpsSqlSchema.ps1 `
  -ServerName "<server>.database.windows.net" `
  -DatabaseName "FinOpsMaccRetail"
```

6. If using `finOpsAuthMode=ServicePrincipal`, store the client secret in Key Vault before the first Function run. Managed identity remains the preferred production default.

When `enableKeyVault=true`, this template creates an RBAC-enabled vault and grants the Function identity the `Key Vault Secrets User` role. It does **not** write the secret value. Seed the secret from a secured workstation or deployment process:

```powershell
az keyvault secret set `
  --vault-name "<key-vault-name>" `
  --name "finops-client-secret" `
  --value "<client-secret>"
```

Then deploy with:

```powershell
az deployment group create `
  --resource-group "<resource-group>" `
  --template-file .\infra\bicep\main.bicep `
  --parameters `
    finOpsAuthMode="ServicePrincipal" `
    finOpsClientId="<app-client-id>" `
    enableKeyVault=true
```

If the customer already has a governed Key Vault, leave `enableKeyVault=false`, pass `finOpsClientSecretKeyVaultSecretUri`, and grant the Function managed identity secret-read access to that vault.

## Notes

- The default SQL SKU is `GP_S_Gen5_1`, suitable for small/pilot deployments. This baseline keeps SQL database properties portable across SKUs; tune serverless auto-pause/min-capacity settings later if the customer standardizes on serverless.
- Set `enablePrivateNetworking=true` and `sqlPublicNetworkAccessEnabled=false` when the customer requires SQL private endpoint access. This creates a VNet, delegated Function integration subnet, SQL private endpoint subnet, `privatelink.database.windows.net` private DNS zone, and DNS zone link.
- Function VNet integration requires a Function plan that supports regional VNet integration. Use `functionPlanSkuName="EP1"` or another approved Premium/Dedicated SKU when `enablePrivateNetworking=true`; classic `Y1` consumption is for public-network/local-dev baselines.
- Bicep deployment can still run from your laptop because it is ARM control-plane deployment. SQL schema/data scripts must run from a private-network path after public SQL access is disabled.
- If you use Azure Bastion, deploy/prepare a jump box VM in the VNet or a peered VNet, connect through Bastion, clone/copy this repository, and run `Deploy-FinOpsSqlSchema.ps1` from that VM.
- The Function App defaults to `FINOPS_EXTRACTION_MODE=Native` and `FINOPS_AUTH_MODE=ManagedIdentity`.
- For service-principal auth, never put `FINOPS_CLIENT_SECRET` directly in app settings. Use `finOpsClientSecretKeyVaultSecretUri` or `enableKeyVault=true` so the Function app setting is a Key Vault reference.
- Monitoring alerts are disabled by default. Set `enableMonitoringAlerts=true` to deploy two App Insights scheduled-query alerts:
  - `FinOps ingestion run failed`: fires when the runner logs `FinOpsRunStatus=Failed`.
  - `FinOps ingestion success missing`: fires when no `FinOpsRunStatus=Succeeded` trace is observed inside `missedRunAlertWindowHours`.
- If `alertNotificationEmail` is blank, alert rules deploy without an email action group so customers can attach their own action group later.
- `role-assignments.bicep` is intentionally separate from `main.bicep` because role grants normally target one or more subscriptions, management groups, or billing scopes that are distinct from the resource group where the Function App is deployed.
