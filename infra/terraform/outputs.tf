output "sql_server_fqdn" {
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "sql_database_name" {
  value = azurerm_mssql_database.this.name
}

output "function_app_name" {
  value = azurerm_windows_function_app.this.name
}

output "function_principal_id" {
  value = azurerm_windows_function_app.this.identity[0].principal_id
}

output "storage_account_name" {
  value = azurerm_storage_account.function.name
}

output "next_steps" {
  value = [
    "Grant the Function managed identity Cost Management Reader on target subscriptions or billing scopes.",
    "Grant the Function managed identity SQL access in the database using CREATE USER FROM EXTERNAL PROVIDER and appropriate role grants.",
    "Deploy the functionapp folder as the Function App package.",
    "Run scripts/Deploy-FinOpsSqlSchema.ps1 or include schema deployment in a controlled release pipeline."
  ]
}
