# Bicep deployment

This folder contains the first enterprise deployment baseline for the Azure FinOps MACC Retail durable-store architecture.

It deploys:

- Azure Storage account for the Function runtime
- Application Insights
- Azure SQL logical server
- Azure SQL database
- optional SQL firewall rule
- optional VNet, NAT Gateway (fixed Function outbound egress IP), Function App private endpoint, and `privatelink.azurewebsites.net` private DNS zone/link
- optional ARM private endpoint and `privatelink.azure.com` private DNS for Cost Management and Microsoft.Billing calls
- optional jump box VM plus Azure Bastion for private administrative access to the Function App once it is behind a private endpoint
- PowerShell Azure Function App with system-assigned managed identity
- Function app settings for native FinOps ingestion
- optional RBAC-enabled Azure Key Vault for service-principal secrets
- optional Azure Monitor scheduled-query alerts backed by Application Insights traces

This folder also includes `role-assignments.bicep`, a separate subscription-scope helper for assigning Azure RBAC roles to the Function managed identity.

ARM Private Link uses three intentionally separate deployments:

- `arm-private-link-resource.bicep` creates the tenant-shared resource-management private link in a platform subscription.
- `arm-private-link-association.bicep` associates that resource with the tenant root management group.
- `main.bicep` optionally creates the workload VNet private endpoint and DNS configuration that the Function uses.

This separation prevents routine Function deployments from requiring root-management-group permissions.

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
    sqlAllowedClientIp="<your-workstation-public-ip>" `
    enableJumpBox=true `
    jumpBoxSshPublicKey="ssh-ed25519 AAAA...your-public-key..." `
    enableKeyVault=true `
    enableMonitoringAlerts=true `
    alertNotificationEmail="finops-ops@example.com"
```

## Deploy ARM Private Link

For a customer-led session without Bastion, follow the [complete customer walkthrough](../../docs/ARM_Private_Link_Customer_Walkthrough.md), including parameter preparation, deployment previews, SQL and Function setup, private-path testing, and rollback.

ARM Private Link is an opt-in Azure Commercial deployment. It does not create a dedicated Cost Management private endpoint; it privately routes the solution's existing Azure Resource Manager calls.

This is a proof-of-concept implementation, not a validated customer deployment. Confirm support for the exact Cost Management query and supporting billing operations with Microsoft, and complete the [acceptance checks](../../docs/Cost_Management_Private_Link_Guide.md#validation-and-acceptance) in an approved test environment before production rollout.

Required deployment access:

- Owner on the platform subscription used for the resource-management private link.
- Owner or Contributor on the tenant root management group for the association.
- The normal workload deployment permissions for the Function resource group and VNet.

Register the required providers in both subscriptions and wait for registration to complete:

```powershell
az provider register --subscription "<platform-subscription-id>" --namespace Microsoft.Authorization --wait
az provider register --subscription "<platform-subscription-id>" --namespace Microsoft.Network --wait
az provider register --subscription "<workload-subscription-id>" --namespace Microsoft.Authorization --wait
az provider register --subscription "<workload-subscription-id>" --namespace Microsoft.Network --wait
```

First, create the resource-management private link in a platform subscription:

```powershell
$resourceManagementPrivateLinkId = az deployment sub create `
  --subscription "<platform-subscription-id>" `
  --location "<deployment-location>" `
  --template-file .\infra\bicep\arm-private-link-resource.bicep `
  --parameters `
    location="<resource-location>" `
    resourceGroupName="rg-arm-private-link" `
    resourceManagementPrivateLinkName="arm-private-link" `
  --query properties.outputs.resourceManagementPrivateLinkId.value `
  --output tsv
```

Next, associate it with the tenant's root management group. The deployment target must be the root management group, not a child management group:

```powershell
az deployment mg create `
  --management-group-id "<root-management-group-id>" `
  --location "<deployment-location>" `
  --template-file .\infra\bicep\arm-private-link-association.bicep `
  --parameters resourceManagementPrivateLinkId="$resourceManagementPrivateLinkId"
```

Finally, deploy the workload with an Elastic Premium Function plan, VNet integration, and the ARM private endpoint:

```powershell
az deployment group create `
  --resource-group "<workload-resource-group>" `
  --template-file .\infra\bicep\main.bicep `
  --parameters .\infra\bicep\main.arm-private-link.parameters.example.json `
  --parameters resourceManagementPrivateLinkId="$resourceManagementPrivateLinkId"
```

Copy the example parameter file before use and replace every placeholder. The deployment rejects these unsafe or unsupported combinations:

- `enablePrivateNetworking=true` with the classic `Y1` plan.
- ARM Private Link without Function VNet integration.
- ARM Private Link without an approved resource-management private-link ID.
- ARM Private Link for a cloud other than Azure Commercial.
- ARM Private Link and this template's Azure Bastion deployment in the same VNet.

The workload deployment creates:

- A private endpoint in `snet-private-endpoints` targeting `ResourceManagement`.
- The `privatelink.azure.com` private DNS zone and VNet link.
- The private endpoint DNS zone group, which creates the `management` record.

The application continues to call `https://management.azure.com`; do not change it to a private IP or private-link hostname.

### Validate the path

Run these checks from the Function execution environment or an approved host that uses the same VNet DNS:

1. Confirm `management.azure.com` resolves to the ARM private endpoint's RFC1918 address.
2. Confirm the private endpoint connection state is `Approved`.
3. Run the actual authorized subscription-scoped Cost Management query.
4. Confirm network logs show TCP 443 to the private endpoint IP.
5. Deny public ARM egress in a controlled test and repeat the query.
6. Confirm subscription discovery and the enabled Microsoft.Billing audit calls still work.

The `armPrivateEndpointId` deployment output identifies the endpoint to inspect. Obtain its approved IPs from its network interface (not from the DNS response being tested):

```powershell
$nicId = az network private-endpoint show --ids "<armPrivateEndpointId>" --query "networkInterfaces[0].id" --output tsv
az network nic show --ids "$nicId" --query "ipConfigurations[].privateIPAddress" --output tsv
```

From the Function execution environment, run the read-only diagnostic using those addresses:

```powershell
.\scripts\Test-FinOpsArmPrivateLink.ps1 `
  -ExpectedPrivateIpAddress "10.40.2.10" `
  -SubscriptionId "<subscription-id>" `
  -AuthMode ManagedIdentity
```

The diagnostic rejects unexpected DNS addresses before authentication, reads subscription metadata, and submits a one-day Cost Management query using the ingestion API version. It outputs no cost rows or tokens, and treats authorization failures as failures. Use `-AuthMode Existing` only for an already authenticated Az.Accounts session; this does not validate the Function's managed identity.

`PrivateTransportVerified` deliberately remains false: the diagnostic cannot replace network logs and the public-egress-denial test. Repeat the check for every subscription, validate the full ingestion queries and enabled billing operations, and complete an end-to-end ingestion run before acceptance.

Run the diagnostic's offline regression checks from the repository root with `pwsh -NoProfile -File tests/Test-FinOpsArmPrivateLink.Tests.ps1`. These use isolated authentication/API fixtures and numeric resolver inputs; they do not contact Azure or validate a deployment.

Private DNS and a successful HTTP response alone do not prove private transport. Azure currently requires the root association's public network access to remain enabled, so customer firewall/UDR policy is required when the Function must be prevented from falling back to public ARM.

The Retail Prices API at `prices.azure.com`, Microsoft identity endpoints, telemetry, deployment, and other platform dependencies are separate outbound paths. ARM Private Link does not privatize them.

### Bastion and administration

Do not link `privatelink.azure.com` to a VNet hosting Azure Bastion. This template therefore rejects `enableArmPrivateLink=true` with `enableJumpBox=true`.

Use a separate management VNet for Bastion and administrative hosts, peered to the workload VNet. Link only the service-specific private DNS zones needed by those administrative hosts; do not expose the ARM private DNS override to the Bastion VNet. Alternatively, deploy and troubleshoot through a VPN/ExpressRoute path or a self-hosted agent in the approved private network.

With private networking enabled, SQL, runtime Storage, and Function inbound access use private endpoints and have public access disabled. NAT Gateway provides static egress for remaining public dependencies; it does not enforce private-only ARM access.

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
- Set `enablePrivateNetworking=true` to create the VNet, delegated Function integration subnet with NAT Gateway, and private endpoints/DNS for Function inbound access, SQL, and runtime Storage. Public access to the Function, SQL, and runtime Storage is disabled. `sqlAllowedClientIp` applies only to the non-private SQL path; it does not grant access to private SQL.
- Set `enableArmPrivateLink=true` only after deploying and associating the resource-management private link. Pass its resource ID through `resourceManagementPrivateLinkId`; the workload deployment then creates the endpoint and ARM private DNS configuration.
- Set `enableJumpBox=true` (requires `enablePrivateNetworking=true`) to deploy a small Linux jump box VM plus Azure Bastion (Basic SKU) so you can privately reach the Function App once `publicNetworkAccess` is disabled on it. Provide `jumpBoxSshPublicKey` with your SSH public key. Connect via **Azure Portal > Bastion > Connect** using that key, then browse `https://<functionAppName>.scm.azurewebsites.net` from the jump box to view Kudu/logs, or use `curl`/`Invoke-RestMethod` to test connectivity — the private DNS zone resolves these hostnames to the private endpoint from inside the VNet.
- Function VNet integration in this template requires an Elastic Premium Function plan. Use `functionPlanSkuName="EP1"`, `EP2`, or `EP3` when `enablePrivateNetworking=true`; classic `Y1` consumption is for public-network/local-dev baselines and does not support this template's VNet integration.
- When `enablePrivateNetworking=true`, `publicNetworkAccess` on the Function App is set to `Disabled`. This also blocks the public deployment/SCM path. Deploy from an approved private-network workstation or agent with SCM DNS/connectivity. See the [customer walkthrough](../../docs/ARM_Private_Link_Customer_Walkthrough.md#10-package-and-deploy-the-function-through-the-private-path) for the application package layout; the repository's `scripts` must be included, not just the `functionapp` folder.
- Bicep deployment can still run from your laptop because it is ARM control-plane deployment. SQL schema/data scripts must run from a private-network path after public SQL access is disabled.
- If you use Azure Bastion, deploy/prepare a jump box VM in the VNet or a peered VNet, connect through Bastion, clone/copy this repository, and run `Deploy-FinOpsSqlSchema.ps1` from that VM.
- The Function App defaults to `FINOPS_EXTRACTION_MODE=Native` and `FINOPS_AUTH_MODE=ManagedIdentity`.
- For service-principal auth, never put `FINOPS_CLIENT_SECRET` directly in app settings. Use `finOpsClientSecretKeyVaultSecretUri` or `enableKeyVault=true` so the Function app setting is a Key Vault reference.
- Monitoring alerts are disabled by default. Set `enableMonitoringAlerts=true` to deploy two App Insights scheduled-query alerts:
  - `FinOps ingestion run failed`: fires when the runner logs `FinOpsRunStatus=Failed`.
  - `FinOps ingestion success missing`: fires when no `FinOpsRunStatus=Succeeded` trace is observed inside `missedRunAlertWindowHours`.
- If `alertNotificationEmail` is blank, alert rules deploy without an email action group so customers can attach their own action group later.
- `role-assignments.bicep` is intentionally separate from `main.bicep` because role grants normally target one or more subscriptions, management groups, or billing scopes that are distinct from the resource group where the Function App is deployed.
