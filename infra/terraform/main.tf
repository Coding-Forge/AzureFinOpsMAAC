data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

locals {
  normalized_workload    = replace(replace(lower(var.workload_name), "_", ""), "-", "")
  normalized_environment = replace(replace(lower(var.environment_name), "_", ""), "-", "")
  storage_account_name   = substr("${local.normalized_workload}${local.normalized_environment}${random_string.suffix.result}", 0, 24)
  app_insights_name      = "${var.workload_name}-${var.environment_name}-appi"
  plan_name              = "${var.workload_name}-${var.environment_name}-plan"
  function_app_name      = "${var.workload_name}-${var.environment_name}-${random_string.suffix.result}-func"
}

resource "azurerm_storage_account" "function" {
  name                            = local.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_application_insights" "this" {
  name                = local.app_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
  retention_in_days   = var.app_insights_retention_days
}

resource "azurerm_mssql_server" "this" {
  name                          = var.sql_server_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = "12.0"
  public_network_access_enabled = var.sql_public_network_access_enabled

  azuread_administrator {
    login_username              = var.sql_entra_admin_login
    object_id                   = var.sql_entra_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }

  lifecycle {
    precondition {
      condition     = var.sql_entra_admin_login != "" && var.sql_entra_admin_object_id != ""
      error_message = "sql_entra_admin_login and sql_entra_admin_object_id are required for Entra-only SQL authentication."
    }
  }
}

resource "azurerm_mssql_database" "this" {
  name           = var.sql_database_name
  server_id      = azurerm_mssql_server.this.id
  sku_name       = var.sql_sku_name
  max_size_gb    = var.sql_max_size_gb
  zone_redundant = false
}

resource "azurerm_mssql_firewall_rule" "deployment_client" {
  count            = var.sql_public_network_access_enabled && var.sql_allowed_client_ip != "" ? 1 : 0
  name             = "AllowDeploymentClient"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = var.sql_allowed_client_ip
  end_ip_address   = var.sql_allowed_client_ip
}

resource "azurerm_service_plan" "function" {
  name                = local.plan_name
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Windows"
  sku_name            = var.function_plan_sku_name
}

resource "azurerm_windows_function_app" "this" {
  name                       = local.function_app_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  service_plan_id            = azurerm_service_plan.function.id
  storage_account_name       = azurerm_storage_account.function.name
  storage_account_access_key = azurerm_storage_account.function.primary_access_key
  https_only                 = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    minimum_tls_version = "1.2"
    ftps_state          = "Disabled"

    application_stack {
      powershell_core_version = var.function_powershell_version
    }
  }

  app_settings = {
    FUNCTIONS_EXTENSION_VERSION              = "~4"
    FUNCTIONS_WORKER_RUNTIME                 = "powershell"
    APPLICATIONINSIGHTS_CONNECTION_STRING    = azurerm_application_insights.this.connection_string
    APPINSIGHTS_INSTRUMENTATIONKEY           = azurerm_application_insights.this.instrumentation_key
    FINOPS_TIMER_SCHEDULE                    = var.finops_timer_schedule
    FINOPS_EXTRACTION_MODE                   = "Native"
    FINOPS_AUTH_MODE                         = "ManagedIdentity"
    FINOPS_AZURE_CLOUD                       = var.finops_azure_cloud
    FINOPS_TENANT_ID                         = var.finops_tenant_id
    FINOPS_SUBSCRIPTION_IDS                  = var.finops_subscription_ids
    FINOPS_SQL_ENABLED                       = "true"
    FINOPS_SQL_SERVER                        = azurerm_mssql_server.this.fully_qualified_domain_name
    FINOPS_SQL_DATABASE                      = azurerm_mssql_database.this.name
    FINOPS_SQL_SCHEMA                        = var.sql_schema_name
  }
}
