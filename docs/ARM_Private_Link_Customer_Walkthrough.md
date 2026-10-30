# ARM Private Link: Customer Deployment Walkthrough (Without Bastion)

## Purpose and deployment status

Use this document to walk through an **Azure Commercial proof of concept** for private connectivity from the FinOps Function App to Azure Resource Manager (ARM), including the solution's Cost Management queries.

The infrastructure templates compile and the connectivity diagnostic has passed offline regression checks. **The integration has not been validated in Azure.** Obtain Microsoft confirmation for the required Cost Management operations and complete the acceptance checks below before production approval.

This walkthrough does not deploy Azure Bastion or a jump box. It retains Azure SQL as the solution's durable data store. SQL is not required by ARM Private Link itself, but is part of this solution's workload template.

The Function continues using `https://management.azure.com` and managed identity. Private DNS is intended to resolve that hostname to the ARM private endpoint. Do not change application URLs to private IP addresses or disable TLS validation.

### What will be deployed

| Deployment | Template | Purpose |
|---|---|---|
| Platform subscription | `infra/bicep/arm-private-link-resource.bicep` | Create the resource-management private link in a platform resource group. |
| Tenant root management group | `infra/bicep/arm-private-link-association.bicep` | Associate that private link with the tenant root management group. |
| Workload resource group | `infra/bicep/main.bicep` | Deploy the Function, SQL, runtime Storage, monitoring, VNet, NAT Gateway, service private endpoints, ARM private endpoint, and DNS. |
| Each ingested subscription | `infra/bicep/role-assignments.bicep` | Grant the Function identity Cost Management Reader. |

**Important:** `main.bicep` is not an ARM-private-endpoint-only template. It manages the broader workload and disables public access to the Function, SQL, and runtime Storage when private networking is enabled. Review the proposed changes before applying them to existing resources.

ARM Private Link does not privatize Retail Prices, Microsoft identity, telemetry, Power BI refresh, or all deployment/platform dependencies. NAT Gateway is not a firewall. Customer-managed routing and outbound controls are needed to prevent public ARM access.

## 1. Complete the predeployment decisions

Review these items with the customer before running deployment commands.

| Item | Required decision or evidence |
|---|---|
| Product compatibility | Confirm support for `POST /subscriptions/<id>/providers/Microsoft.CostManagement/query?api-version=2023-11-01`, subscription metadata reads, and enabled Billing operations with Microsoft. |
| Tenant | Use one approved tenant. Do not assume one ARM private-link association supports multiple tenants. |
| Governance | Obtain approval for a tenant-root-management-group association. It is not a Function-only configuration. |
| Platform resources | Check for an existing approved resource-management private link and association. Reuse them rather than create competing tenant resources. |
| Region and capacity | Confirm the selected regions support the required resources, the PowerShell runtime, EP1 capacity, and customer policies. Example regions are not a support guarantee. |
| Private administration | Provide VPN/ExpressRoute connectivity or a privately connected deployment agent with routes and DNS to the workload. No Bastion is needed, but a private administration path is. |
| DNS | Approve private DNS links/forwarding for ARM, Function/SCM, SQL, and Storage from the appropriate networks. VPN/peering alone does not provide private DNS. |
| Networking | Reserve non-overlapping VNet/subnet ranges and approve NSGs, routes, peering, and outbound controls. |
| Function hosting/storage | Confirm the hosting and deployment model. If Azure Files content storage is required, add the File endpoint, DNS, and content routing through an approved template adaptation before rollout; the baseline provides Blob, Queue, and Table endpoints only. |
| Billing collection | Decide whether billing auditing is required. It defaults to enabled and can need billing-account/profile permissions beyond subscription RBAC. |
| SQL/reporting | Confirm SQL ownership, an Entra administrator, and the private access/Power BI gateway plan. |
| Cost and recovery | Approve Premium Functions, SQL, NAT Gateway, private endpoints, and monitoring charges, plus a rollback plan. |

Even without deploying Bastion here, check whether shared DNS forwarding would affect an existing Bastion elsewhere. Do not expose the ARM DNS override to a Bastion network.

**Stop here** if API support, tenant approval, a private deployment path, or a required hosting/storage dependency is unresolved.

### Required permissions

The deployment identities need:

- Owner on the subscription hosting the resource-management private link, as listed in Microsoft's setup guidance.
- Owner or Contributor on the **tenant root management group** for the association.
- Workload deployment permissions, including permission to create the role assignments included by `main.bicep`. Contributor alone does not grant role-assignment write access.
- Role-assignment permissions on every subscription being ingested.
- An approved SQL Entra administrator to deploy the schema and create the Function's database user.

These are deployment permissions. **Do not grant tenant-root or deployment-Owner permissions to the Function identity.**

## 2. Collect values and prepare the session

The command examples use **PowerShell 7.4 or later** on an approved workstation/agent, Azure CLI, and Bicep. The SQL schema example uses Windows PowerShell, consistent with the existing SQL deployment instructions. Linux agents need a separately verified SQL-client/runtime setup.

Use the reviewed source/package containing these templates and scripts; do not assume an older release ZIP includes them. Run commands from the repository/package root.

Record the following values in the customer's approved deployment records, not in a public repository:

```powershell
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$tenantId = "<customer-tenant-guid>"
$rootManagementGroupId = $tenantId
$platformSubscriptionId = "<subscription-hosting-the-arm-private-link>"
$workloadSubscriptionId = "<subscription-hosting-the-function-and-sql>"
$targetSubscriptionIds = @("<subscription-to-ingest>")

$location = "<approved-workload-and-platform-resource-region>"
$deploymentLocation = "<approved-arm-deployment-metadata-region>"
$platformResourceGroup = "<platform-resource-group>"
$workloadResourceGroup = "<workload-resource-group>"
$resourceManagementPrivateLinkName = "<approved-resource-management-private-link-name>"

$sqlEntraAdminLogin = "<approved-individual-admin-display-name>"
$sqlEntraAdminObjectId = "<that-user-object-id-in-the-customer-tenant>"
$parameterFile = ".\infra\bicep\main.parameters.json"
$workloadDeploymentName = "finops-arm-private-link-poc"
```

The platform and workload subscriptions may be the same subscription. They must belong to the approved tenant. The template checks that the association is deployed to the tenant root management group, whose ID is the tenant GUID, not its display name.

The current SQL administrator configuration declares `principalType: User`. Use an approved individual administrator for this baseline. If customer policy requires a group or other principal type, adapt and review the template before deploying instead of passing a group object ID unchanged.

Sign in and verify the selected accounts:

```powershell
az cloud set --name AzureCloud
az login --tenant "$tenantId" --output none

az account show --subscription "$platformSubscriptionId" `
  --query "{subscription:id,tenant:tenantId,name:name}" --output table
az account show --subscription "$workloadSubscriptionId" `
  --query "{subscription:id,tenant:tenantId,name:name}" --output table

az bicep version
```

Confirm both tenant IDs match `$tenantId`. Verify root-management-group access with the platform owner. A Global Administrator designation by itself does not establish the necessary Azure resource permissions.

## 3. Copy and update the workload JSON

Copy the example once. Do not overwrite an existing customer parameter file:

```powershell
if (Test-Path $parameterFile) {
    throw "Customer parameter file already exists. Review it instead of overwriting it."
}
Copy-Item .\infra\bicep\main.arm-private-link.parameters.example.json $parameterFile
```

Open `infra/bicep/main.parameters.json` and review each value:

| Parameter | Customer value |
|---|---|
| `workloadName` | Approved short workload name, such as `finops`. |
| `environmentName` | Use a test label such as `poc` for the first deployment. |
| `location` | Same approved workload region as `$location`. |
| `finOpsAzureCloud` | Keep `AzureCloud`. |
| `finOpsAuthMode` | Keep `ManagedIdentity`. |
| `finOpsTenantId` | `$tenantId`. |
| `finOpsSubscriptionIds` | Comma-separated `$targetSubscriptionIds`, without angle-bracket placeholders. |
| `sqlServerName` | Globally unique Azure SQL logical server name, without `.database.windows.net`. |
| `functionPlanSkuName` | Keep `EP1`, unless another supported Elastic Premium size is approved. Do not use `Y1`. |
| `enablePrivateNetworking` | Keep `true`. |
| `enableArmPrivateLink` | Keep `true`. |
| `resourceManagementPrivateLinkId` | Replace after step 5, or use the existing platform-approved resource ID. |
| `enableJumpBox` | Keep `false`; this prevents this template from deploying Bastion and a jump box. |

Review optional parameters against `main.bicep`. The default network ranges are `10.40.0.0/16`, integration subnet `10.40.1.0/24`, and endpoint subnet `10.40.2.0/24`. Add the corresponding parameter entries if those ranges conflict with the customer's network.

The default database/schema names are `FinOpsMaccRetail` and `finops`. SQL administrator values are supplied inline in step 7; they are not present in the example JSON.

For an existing SQL server, use its existing resource group as the workload deployment target and review all proposed changes. The template manages that SQL resource; it is not a read-only reference. Cross-resource-group reuse requires a template adaptation. Do not use this fresh-POC sequence as an in-place migration of an existing Function or hosting plan without a separate migration review.

Keep the customer parameter file private. The selected filename is already ignored by this repository's Git configuration. It must not contain credentials or client secrets.

**Checkpoint:** all placeholders except the private-link resource ID have been replaced, and JSON values match the session variables.

## 4. Register providers and check the templates

Platform owners may perform provider registration separately. Register required namespaces in the subscriptions that will host the resources:

```powershell
foreach ($subscriptionId in @($platformSubscriptionId, $workloadSubscriptionId) | Select-Object -Unique) {
    foreach ($namespace in @("Microsoft.Authorization", "Microsoft.Network")) {
        az provider register --subscription "$subscriptionId" --namespace "$namespace" --wait
    }
}

foreach ($namespace in @("Microsoft.Web", "Microsoft.Storage", "Microsoft.Sql", "Microsoft.Insights")) {
    az provider register --subscription "$workloadSubscriptionId" --namespace "$namespace" --wait
}

az bicep lint --file .\infra\bicep\main.bicep
az bicep lint --file .\infra\bicep\arm-private-link-resource.bicep
az bicep lint --file .\infra\bicep\arm-private-link-association.bicep
```

If enabling optional Key Vault or another optional service, register its provider too. Do not proceed past compilation errors or unresolved policy/registration failures. The known conditional NAT public-IP warning is not evidence that an Azure deployment has been validated.

## 5. Create or reuse the platform resource-management private link

**Platform-owner step.** If the customer already has an approved resource-management private link and root association, record its full resource ID and skip creation of those existing resources:

```powershell
# Reuse path only: replace this with the approved existing resource ID.
$resourceManagementPrivateLinkId = "<approved-existing-resource-id>"
```

For a new resource, preview the platform deployment:

```powershell
az deployment sub what-if `
  --subscription "$platformSubscriptionId" `
  --location "$deploymentLocation" `
  --template-file .\infra\bicep\arm-private-link-resource.bicep `
  --parameters location="$location" resourceGroupName="$platformResourceGroup" `
    resourceManagementPrivateLinkName="$resourceManagementPrivateLinkName"
```

After approval, create it and capture the ID:

```powershell
$resourceManagementPrivateLinkId = az deployment sub create `
  --subscription "$platformSubscriptionId" `
  --name "finops-arm-private-link-platform" `
  --location "$deploymentLocation" `
  --template-file .\infra\bicep\arm-private-link-resource.bicep `
  --parameters location="$location" resourceGroupName="$platformResourceGroup" `
    resourceManagementPrivateLinkName="$resourceManagementPrivateLinkName" `
  --query properties.outputs.resourceManagementPrivateLinkId.value --output tsv

if ([string]::IsNullOrWhiteSpace($resourceManagementPrivateLinkId)) {
    throw "No resource-management private-link ID was returned."
}
```

The returned ID has this structure:

```text
/subscriptions/<platform-subscription>/resourceGroups/<platform-rg>/providers/Microsoft.Authorization/resourceManagementPrivateLinks/<name>
```

Copy the exact ID into `resourceManagementPrivateLinkId.value` in the customer JSON. Do not use the ID of a private endpoint or the association.

## 6. Create or verify the tenant-root association

**Tenant platform-owner step.** Skip creation only if the platform owner has verified the existing root association points to the approved resource from step 5.

For a new association:

```powershell
az deployment mg what-if `
  --management-group-id "$rootManagementGroupId" `
  --location "$deploymentLocation" `
  --template-file .\infra\bicep\arm-private-link-association.bicep `
  --parameters resourceManagementPrivateLinkId="$resourceManagementPrivateLinkId"
```

After the platform owner approves the preview:

```powershell
az deployment mg create `
  --management-group-id "$rootManagementGroupId" `
  --name "finops-arm-private-link-association" `
  --location "$deploymentLocation" `
  --template-file .\infra\bicep\arm-private-link-association.bicep `
  --parameters resourceManagementPrivateLinkId="$resourceManagementPrivateLinkId" `
  --output none
```

The template generates a GUID association name. Record the deployment and association ID in the customer's change record.

**Checkpoint:** the root association references the intended resource-management private link. Microsoft currently requires its `publicNetworkAccess` to remain enabled. Do not change it to `Disabled`; enforce the Function's public ARM restriction through customer outbound controls.

## 7. Preview and deploy the workload

Check whether the approved workload resource group exists:

```powershell
az group exists --subscription "$workloadSubscriptionId" `
  --name "$workloadResourceGroup" --output tsv
```

If the result is `true`, verify the existing group's location and ownership with `az group show` rather than changing them. If the result is `false`, create it:

```powershell
az group create --subscription "$workloadSubscriptionId" `
  --name "$workloadResourceGroup" --location "$location" --output none
```

Preview the complete workload. The explicit private-link ID below must match the JSON:

```powershell
az deployment group what-if `
  --subscription "$workloadSubscriptionId" `
  --resource-group "$workloadResourceGroup" `
  --template-file .\infra\bicep\main.bicep `
  --parameters "$parameterFile" `
  --parameters resourceManagementPrivateLinkId="$resourceManagementPrivateLinkId" `
    sqlEntraAdminLogin="$sqlEntraAdminLogin" sqlEntraAdminObjectId="$sqlEntraAdminObjectId"
```

Review resource names, EP1 cost, SQL settings, subnet ranges, private endpoints, DNS zones, role assignments, and public-access changes. Confirm no Bastion or jump box is proposed. Investigate unexpected modifications, replacements, or deletions.

After approval:

```powershell
az deployment group create `
  --subscription "$workloadSubscriptionId" `
  --resource-group "$workloadResourceGroup" `
  --name "$workloadDeploymentName" `
  --template-file .\infra\bicep\main.bicep `
  --parameters "$parameterFile" `
  --parameters resourceManagementPrivateLinkId="$resourceManagementPrivateLinkId" `
    sqlEntraAdminLogin="$sqlEntraAdminLogin" sqlEntraAdminObjectId="$sqlEntraAdminObjectId" `
  --output none

$outputs = az deployment group show `
  --subscription "$workloadSubscriptionId" `
  --resource-group "$workloadResourceGroup" --name "$workloadDeploymentName" `
  --query properties.outputs --output json | ConvertFrom-Json

$functionAppName = $outputs.functionAppName.value
$functionPrincipalId = $outputs.functionPrincipalId.value
$sqlServerFqdn = $outputs.sqlServerFullyQualifiedDomainName.value
$sqlDatabaseName = $outputs.sqlDatabase.value
$armPrivateEndpointId = $outputs.armPrivateEndpointId.value
```

Before deploying application code, keep scheduled ingestion disabled while permissions, schema, and private connectivity are prepared:

```powershell
az functionapp config appsettings set `
  --subscription "$workloadSubscriptionId" --resource-group "$workloadResourceGroup" `
  --name "$functionAppName" `
  --settings "AzureWebJobs.FinOpsIngestionTimer.Disabled=true" --output none
```

This operational setting is not managed by the baseline template. Reapply it if infrastructure redeployment replaces app settings during commissioning, and persist the customer's desired schedule controls in their deployment system.

## 8. Grant the runtime identity access

Grant Cost Management Reader separately on every subscription being ingested:

```powershell
foreach ($subscriptionId in $targetSubscriptionIds) {
    az deployment sub create `
      --subscription "$subscriptionId" --location "$deploymentLocation" `
      --name "finops-cost-reader" `
      --template-file .\infra\bicep\role-assignments.bicep `
      --parameters functionPrincipalId="$functionPrincipalId" --output none
}
```

Allow time for managed-identity and RBAC propagation. If billing auditing is enabled, have the billing owner grant the additional permissions for the actual billing scopes. Subscription Cost Management Reader alone is not a guarantee of Billing API access.

Do not grant blanket subscription Owner to fix a runtime authorization failure. If billing collection is intentionally excluded from the agreed POC, set `FINOPS_RUN_BILLING_AUDIT=false` using the customer's controlled app-settings process and record that billing has not been validated.

## 9. Establish private SQL access and deploy the schema

Perform this step from the **approved privately connected Windows workstation/agent**, not an ordinary public-only workstation or unconnected Cloud Shell.

Verify private SQL DNS and TCP connectivity:

```powershell
Resolve-DnsName "$sqlServerFqdn"
Test-NetConnection "$sqlServerFqdn" -Port 1433
```

DNS must lead to the intended SQL private endpoint and TCP connectivity must succeed. Additional SQL connectivity requirements depend on the customer's connection policy. Do not open public SQL access as a workaround.

In that private session, sign Azure CLI into the customer tenant and select the workload subscription. Using the approved SQL Entra administrator:

```powershell
az login --tenant "$tenantId" --output none
az account set --subscription "$workloadSubscriptionId"

powershell.exe -NoProfile -File .\scripts\Deploy-FinOpsSqlSchema.ps1 `
  -ServerName "$sqlServerFqdn" -DatabaseName "$sqlDatabaseName"
if ($LASTEXITCODE -ne 0) { throw "SQL schema deployment failed." }
```

The database was created by Bicep; do not use `-CreateDatabase` or `-DropExistingTables` for this walkthrough.

Connect to the target database with an approved SQL client using Entra authentication as the SQL administrator. Replace the placeholder with the actual `$functionAppName` and run:

```sql
CREATE USER [<function-app-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<function-app-name>];
ALTER ROLE db_datawriter ADD MEMBER [<function-app-name>];
```

For an existing database, check for the user and existing grants first rather than blindly recreating it. These are the baseline data-access roles; the customer can replace them with a reviewed narrower permission model.

If `CREATE USER` cannot resolve the managed identity, have the SQL/identity team resolve the logical server's directory lookup requirements. Do not give the Function broad Microsoft Graph permissions as a shortcut.

## 10. Package and deploy the Function through the private path

The Function's SCM/deployment endpoint is private. The deployment workstation/agent must resolve and reach both:

```text
<function-app-name>.azurewebsites.net
<function-app-name>.scm.azurewebsites.net
```

Use an approved private deployment pipeline or prepare a ZIP as follows from the solution root. This copies application code only, not exports, customer parameter files, or the release archive:

```powershell
$packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("finops-function-" + [guid]::NewGuid().ToString("N"))
$zipPath = "$packageRoot.zip"
New-Item -ItemType Directory -Path $packageRoot | Out-Null
Copy-Item .\functionapp\* -Destination $packageRoot -Recurse
New-Item -ItemType Directory -Path (Join-Path $packageRoot "scripts") | Out-Null
Copy-Item -Path @(".\scripts\*.ps1", ".\scripts\*.psm1") `
  -Destination (Join-Path $packageRoot "scripts")
Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $zipPath
```

Verify `host.json` is at the ZIP root and the package contains:

```text
host.json
profile.ps1
requirements.psd1
FinOpsIngestionTimer/function.json
FinOpsIngestionTimer/run.ps1
scripts/Invoke-FinOpsServerlessRun.ps1
scripts/FinOpsNativeAuth.psm1
scripts/Test-FinOpsArmPrivateLink.ps1
scripts/<other application PowerShell scripts>
```

Deploy from the privately connected session:

```powershell
az functionapp deployment source config-zip `
  --subscription "$workloadSubscriptionId" --resource-group "$workloadResourceGroup" `
  --name "$functionAppName" --src "$zipPath" --output none
```

Use the customer's approved deployment authentication. If policy disables the authentication required by this ZIP-deployment route, use their supported private pipeline rather than enabling basic publishing credentials or public access solely to make this command work.

The package requires Az.Accounts through Function managed dependencies. Approve its dependency-download path or prepackage dependencies using the customer's supported deployment process. Confirm the selected deployment model provides writable output/history locations; read-only run-from-package deployments require explicitly configured writable `FINOPS_OUTPUT_ROOT` and `FINOPS_HISTORY_ROOT` paths.

Verify the host starts and the timer is indexed but still disabled. Retain the reviewed source and deployment evidence; remove the specifically created temporary staging directory/ZIP afterward using the customer's cleanup process.

## 11. Verify the ARM endpoint and obtain its expected IPs

From an authorized administration session:

```powershell
az network private-endpoint show `
  --subscription "$workloadSubscriptionId" --ids "$armPrivateEndpointId" `
  --query "privateLinkServiceConnections[].privateLinkServiceConnectionState" --output table

$armNicId = az network private-endpoint show `
  --subscription "$workloadSubscriptionId" --ids "$armPrivateEndpointId" `
  --query "networkInterfaces[0].id" --output tsv

$armPrivateIps = @(az network nic show `
  --subscription "$workloadSubscriptionId" --ids "$armNicId" `
  --query "ipConfigurations[].privateIPAddress" --output tsv)
```

All relevant connection states must be **Approved**. If approval is pending, the platform owner must approve the connection through the resource-management private link before testing.

Record the IPs from the endpoint NIC independently of DNS. Verify `privatelink.azure.com` has the `management` record and is linked to the workload VNet. Check custom-DNS forwarding where applicable.

An administration network can intentionally have different ARM DNS from the workload. Success from an administrator's laptop is not proof of the Function's path.

## 12. Run the authorized check in the Function execution environment

Use the customer's approved in-app diagnostic mechanism to execute the deployed script with the **Function's identity and effective network/DNS**. If using a private Kudu/SCM console, verify that its execution context exposes those same facilities; a console on another host, build worker, or agent must not be assumed equivalent.

In that environment, substitute the NIC IPs and ingested subscriptions recorded earlier:

```powershell
& .\scripts\Test-FinOpsArmPrivateLink.ps1 `
  -ExpectedPrivateIpAddress @("<arm-endpoint-private-ip>") `
  -SubscriptionId @("<ingested-subscription-guid>") `
  -AuthMode ManagedIdentity `
  -TenantId "<customer-tenant-guid>"
```

Run from the deployed application root, or use the script's full path. Administration-session variables do not automatically exist inside the Function session.

Expected results for every subscription:

- ARM resolves exclusively to approved endpoint IPs.
- Subscription metadata and the bounded Cost Management query succeed.
- No cost rows or tokens are printed by the diagnostic.
- `PrivateTransportVerified` remains `false` by design.

That last field is not a failed API check: it prevents DNS/API success from being misrepresented as proof of the transport path.

An HTTP 401/403 is a failed acceptance check, not a successful connectivity result. Resolve identity/RBAC issues and repeat. Do not substitute `-AuthMode Existing` with an administrator's account for testing the Function identity.

If the execution environment cannot be demonstrated to match the Function, stop and establish an approved in-process diagnostic path. A test from a nearby VM/agent is useful preliminary evidence, but is not final acceptance.

## 13. Enforce and prove the private ARM path

**Customer network-team step.** The baseline supplies VNet integration and private DNS but not a firewall/UDR policy that denies public ARM access.

Have the customer configure and review their approved outbound design:

1. Allow the Function's private TCP 443 path to the ARM endpoint.
2. Deny the Function's public ARM path, including any proxy or alternate route that could bypass that restriction.
3. Retain only approved public dependencies for Retail Prices, identity, certificate validation, deployment, managed dependencies, and other required platform services.
4. Repeat step 12 with public ARM egress denied.
5. Capture network evidence showing the actual connection destination is the private endpoint IP. Verify that the selected logging point can see this traffic; private-endpoint flows may bypass a default-route firewall.
6. Under an approved test/change plan, make the workload's private ARM path unavailable and confirm its queries fail rather than succeeding through public ARM. Restore the private path and repeat the positive test.

An FQDN allow rule for `management.azure.com`, NAT Gateway, route-all application settings, or DNS resolution alone does not prove private-only transport. Review configuration/platform traffic separately if the customer requires all application dependencies to be private.

Do not enable `publicNetworkAccess=Disabled` on the tenant-root association; Microsoft does not currently support that setting. Do not link the ARM DNS zone broadly as a shortcut.

## 14. Complete a scheduled ingestion run

After permissions, SQL, dependency access, and the private ARM checks are ready, enable the timer under the approved change:

```powershell
az functionapp config appsettings set `
  --subscription "$workloadSubscriptionId" --resource-group "$workloadResourceGroup" `
  --name "$functionAppName" `
  --settings "AzureWebJobs.FinOpsIngestionTimer.Disabled=false" --output none
```

The default schedule is `0 0 6 * * *` (06:00 UTC daily). Wait for the approved scheduled run, or use a customer-approved administrative trigger. Changing the schedule for testing must be recorded and reverted afterward.

Confirm the actual ingestion succeeds with public ARM egress still denied. It exercises more query shapes than the bounded diagnostic. Include enabled billing operations, retail enrichment, SQL loading, runtime Storage, and monitoring.

Expected host markers:

```text
FinOpsRunStatus=Started
FinOpsRunStatus=Succeeded
```

Confirm the database has fresh expected data and review these operational views using the approved SQL client:

```sql
SELECT * FROM finops.OperationalHealthSummary;
SELECT * FROM finops.IngestionFreshnessBySubscription;
```

Use the configured schema if it differs from `finops`. Keep diagnostic records, logs, query outputs, and customer data in approved customer storage. Do not share access tokens, publishing credentials, raw cost rows, or billing contacts as deployment evidence.

## 15. Acceptance, troubleshooting, and rollback

### Acceptance record

Do not describe the deployment as private-only or production-ready until the customer has recorded:

- Microsoft compatibility confirmation and approval for the tested operation/scopes.
- Successful platform, root-association, and workload deployments.
- Approved endpoint state and Function-side DNS evidence matching the endpoint NIC.
- Successful authorized queries for every intended subscription and enabled billing scope.
- Positive private-transport evidence with public ARM egress denied.
- A negative test proving no public fallback when the private path is unavailable.
- A successful ingestion run, SQL freshness, functioning private administration/deployment, and the report-refresh plan.
- Accepted public exceptions, costs, operating owners, and a tested recovery procedure.

### Common blockers

| Symptom | Check or action |
|---|---|
| Root association deployment fails | Confirm the tenant root ID, deploying identity's access, and approved private-link ID. Do not grant the runtime identity tenant-wide deployment rights. |
| Private endpoint is Pending | Ask the platform resource owner to review/approve the connection. |
| ARM resolves publicly | Inspect zone group/record, VNet link, effective DNS servers, forwarding, and caches from the Function context. |
| Endpoint DNS is correct but calls time out | Inspect routes, NSGs, proxies, and endpoint availability; capture network evidence. |
| API returns 401/403 | Check Function identity, tenant, subscription roles, billing permissions, and propagation. Network access does not grant authorization. |
| SQL schema or user creation fails | Verify private SQL access, the SQL Entra administrator, and directory lookup permissions. |
| ZIP deployment returns 403/times out | Verify private SCM DNS/connectivity and approved deployment authentication. Do not turn public access back on as a shortcut. |
| Host cannot start or download dependencies | Review runtime, managed-dependency, and content-storage requirements, including Azure Files if the selected hosting model uses it. |
| Diagnostic succeeds but full ingestion fails | Review all query shapes, billing scope permissions, retail/platform egress, writable paths, SQL, and logs. A small successful query is not end-to-end acceptance. |

### Rollback

Pause ingestion first by setting `AzureWebJobs.FinOpsIngestionTimer.Disabled=true`. Preserve the deployment outputs and failure evidence.

Revert only the workload-specific changes introduced by this change, using the recorded prior configuration and customer-approved IaC. For a fresh POC, do not delete the workload resource group without reviewing SQL/data retention, ownership, and shared dependencies.

Do not remove shared platform private links, root associations, or shared DNS zones as part of workload rollback without the platform owner's approval.

Restore public ARM connectivity only if customer policy explicitly permits it. Otherwise leave ingestion paused and report the blocker; do not silently fall back to public access.

## Related documentation

- [Bicep deployment reference](../infra/bicep/README.md#deploy-arm-private-link)
- [Private Link design, support gates, validation, and rollback](Cost_Management_Private_Link_Guide.md)
- [Customer ownership and handoff](Cost_Management_Private_Link_Customer_Handoff_Addendum.md)
- [Microsoft ARM Private Link setup and limitations](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/create-private-link-access-commands)
- [Microsoft Functions networking options](https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options)
