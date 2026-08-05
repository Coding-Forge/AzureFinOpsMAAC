# Terraform deployment

This folder contains the Terraform equivalent of the Bicep deployment baseline for the Azure FinOps MACC Retail durable-store architecture.

It deploys:

- Azure Storage account for the Function runtime
- Application Insights
- Azure SQL logical server
- Azure SQL database
- optional SQL firewall rule
- PowerShell Azure Function App with system-assigned managed identity
- Function app settings for native FinOps ingestion

## Deploy

Copy the example variables file and edit it:

```powershell
copy .\infra\terraform\terraform.tfvars.example .\infra\terraform\terraform.tfvars
```

Then deploy:

```powershell
cd infra\terraform
terraform init
terraform plan
terraform apply
```

The baseline expects an existing Azure resource group. Set `resource_group_name` in `terraform.tfvars`.

## Required post-deployment steps

1. Deploy the `functionapp` folder to the created Function App.
2. Grant the Function managed identity Cost Management Reader on the target subscriptions, management groups, or billing scopes.
3. Grant the Function managed identity any required Billing Reader/Billing account roles for billing evidence.
4. Grant the Function managed identity access to Azure SQL:

```sql
CREATE USER [<function-app-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<function-app-name>];
ALTER ROLE db_datawriter ADD MEMBER [<function-app-name>];
```

5. Deploy the SQL schema:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ..\..\scripts\Deploy-FinOpsSqlSchema.ps1 `
  -ServerName "<server>.database.windows.net" `
  -DatabaseName "FinOpsMaccRetail"
```

## Notes

- The default SQL SKU is `GP_S_Gen5_1`, suitable for small/pilot deployments.
- Set `sql_public_network_access_enabled=false` when the customer requires private endpoint access. Private endpoint wiring will be expanded in a later hardening pass.
- The Function App defaults to `FINOPS_EXTRACTION_MODE=Native` and `FINOPS_AUTH_MODE=ManagedIdentity`.
- Terraform is not bundled with the solution; install Terraform separately before running this deployment.
